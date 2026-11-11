# The child BEAM of `PlaywrightEx.Test.EndToEndTest`: a suite on `PlaywrightEx.Test`, one
# passing and one failing test, run as `mix test` runs one (`ExUnit.run/0`, then halt).
#
# Runs as `elixir -pa <playwright_ex ebin> test_runner_impl.exs <output dir> <browser> <go file>`.
# It prints "(ready=>true)" in the passing test and waits there until the go file exists.

PlaywrightEx.ClientProcess.halt_on_stdin_eof()
Logger.configure(level: :info)

[output_dir, browser_name, _go] = System.argv()

Application.put_env(:playwright_ex, :test,
  browser_name: String.to_atom(browser_name),
  output_dir: output_dir,
  trace: :retain_on_failure,
  screenshot: :only_on_failure
)

# The test build's .app lists the test-only deps: start the library's own tree.
:ok = Application.load(:playwright_ex)
{:ok, _} = Application.ensure_all_started(:crypto)
{:ok, _} = PlaywrightEx.Application.start(:normal, [])
ExUnit.start(autorun: false, formatters: [ExUnit.CLIFormatter, PlaywrightEx.Test.Formatter])

defmodule SampleTest do
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ExUnit.Case, async: true

  import PlaywrightEx.Test

  alias PlaywrightEx.Page

  setup_all :browser
  setup [:new_context, :new_page]

  test "passes", %{page: page} do
    Page.set_content!(page, "<h1>Passes</h1>")
    IO.puts("(ready=>true)")
    [_, _, go] = System.argv()
    wait = fn wait -> if !File.exists?(go), do: Process.sleep(50) && wait.(wait) end
    wait.(wait)
  end

  test "fails", %{page: page} do
    Page.set_content!(page, "<h1>Fails</h1>")
    flunk("on purpose")
  end
end

ExUnit.run()
System.halt(0)
