# The child process of `PlaywrightEx.ClientProcess`: a BEAM that uses the Elixir client.
#
# Upstream's `tests/config/remote-server-impl.js` for the Elixir client, as Python's
# `tests/helpers/client_process_impl.py`: it launches the browser with the client, then waits
# idle (outside any Playwright call) until the test sends it a signal. It prints "(key=>value)"
# lines, like upstream: (tempDir=>...), (ready=>true), (closed=>success).
#
# Runs as `elixir --erl +Bd -pa <playwright_ex ebin> client_process_impl.exs '<json options>'`.

alias PlaywrightEx.Browser
alias PlaywrightEx.BrowserType
alias PlaywrightEx.Page
alias PlaywrightEx.Playwright

PlaywrightEx.ClientProcess.halt_on_stdin_eof()

options = JSON.decode!(hd(System.argv()))
out = fn key, value -> IO.puts("(#{key}=>#{value})") end

{:ok, _} = PlaywrightEx.Supervisor.start_link(name: :client)
playwright = PlaywrightEx.playwright(:client)

browser_type =
  case options["browserTypeName"] do
    "chromium" -> Playwright.chromium(playwright)
    "firefox" -> Playwright.firefox(playwright)
    "webkit" -> Playwright.webkit(playwright)
  end

# remoteServer.ts: the parent's `_defaultLaunchOptions` (`headless`; no args, channel or executablePath here).
launch_options = [
  headless: PlaywrightEx.TestBrowser.headless(),
  handle_sigint: true,
  handle_sigterm: true,
  handle_sighup: true
]

if options["startStopAndRunHttp"] do
  browser = BrowserType.launch!(browser_type, launch_options)
  Browser.close!(browser)
  out.("closed", "success")
  {:ok, _socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
  Process.sleep(:infinity)
end

browser = BrowserType.launch!(browser_type, launch_options)

# The test points TMPDIR to a directory of its own, where the driver creates the browser's
# user data dir.
case Path.wildcard(Path.join(System.fetch_env!("TMPDIR"), "playwright_*dev_profile-*")) do
  [temp_dir] -> out.("tempDir", temp_dir)
  _ -> out.("tempDir", "unknown")
end

if url = options["url"] do
  page = Browser.new_page!(browser)
  Page.goto!(page, url)
end

out.("ready", "true")

wait = fn wait ->
  if Browser.is_connected(browser) do
    Process.sleep(100)
    file = options["exitOnFile"]
    if file && File.exists?(file), do: System.halt(42)
    wait.(wait)
  end
end

wait.(wait)
