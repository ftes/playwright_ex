# The child BEAM of `PlaywrightEx.NoOrphanProcessesTest`: starts each kind of long-lived OS process
# the tests start (the driver and its browser, `run-server`, `launch-server`,
# `remote-server-impl.js`, a `PlaywrightEx.ClientProcess` BEAM), prints "(ready=>true)" and idles
# until the test kills it with SIGKILL.
#
# Runs as `elixir -pa <playwright_ex ebin> no_orphan_processes_impl.exs <browser name>`.

alias PlaywrightEx.Browser
alias PlaywrightEx.BrowserType
alias PlaywrightEx.Playwright
alias PlaywrightEx.RemoteServer

# Should the test BEAM die meanwhile.
PlaywrightEx.ClientProcess.halt_on_stdin_eof()

[browser_name] = System.argv()
{:ok, _} = PlaywrightEx.Supervisor.start_link(name: :client)
browser_type = apply(Playwright, String.to_existing_atom(browser_name), [PlaywrightEx.playwright(:client)])

browser = BrowserType.launch!(browser_type, %{})
Browser.new_page!(browser)

run_server = RemoteServer.RunServer.start()
connected = BrowserType.connect!(browser_type, RemoteServer.RunServer.ws_endpoint(run_server))
Browser.new_page!(connected)

RemoteServer.LaunchServer.start!(browser_name)
RemoteServer._start(browser_type, %{})
PlaywrightEx.ClientProcess.start(browser_name, %{})

IO.puts("(ready=>true)")
Process.sleep(:infinity)
