defmodule PlaywrightEx.Test.Formatter do
  @moduledoc """
  An ExUnit formatter for `PlaywrightEx.Test`: it deletes the artifacts that a passing test
  retains only on failure (`trace: :retain_on_failure`, `screenshot: :only_on_failure`,
  `video: :retain_on_failure`), and checks in a module's driver of its own (`isolate: true`)
  when the module finishes, discarding it if a test failed.

      # test/test_helper.exs
      ExUnit.start(formatters: [ExUnit.CLIFormatter, PlaywrightEx.Test.Formatter])

  It prints nothing. ExUnit runs a test's `on_exit` callbacks, which write its artifacts, before
  it reports the test to formatters, so the files exist when this one sees the result.
  """
  use GenServer

  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Recorder

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    Recorder.test_finished({test.module, test.name, test.parameters}, test.state == nil)
    {:noreply, state}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{} = module}, state) do
    failed? = match?({:failed, _}, module.state) or Enum.any?(module.tests, &match?(%{state: {:failed, _}}, &1))
    Pool.module_finished({module.name, module.parameters}, failed?)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
