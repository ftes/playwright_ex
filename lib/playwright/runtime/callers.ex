defmodule Playwright.Runtime.Callers do
  @moduledoc """
  Runtime support (not ported from upstream): a process the client starts on one caller's behalf
  (an async function, a user listener's process, a listener process running a user callback:
  routes and their URL matchers, WebSocket routes, bindings, locator handlers, screencast frames)
  carries the `$callers` of that caller or of the callback's registrant, as a `Task` carries its
  caller's (ExUnit's docs suggest forwarding them so, `start_supervised/2`). Shared processes
  (the connection) get none.
  Upstream's `expect`, `test.step` and `testInfo` work in them, as its worker runs one test at a
  time (`currentTestInfo()`); here `Playwright.Test.TestInfo`, the Ecto sandbox, Mox and
  `Req.Test` find the test through `$callers`.

  An unhandled error of such a callback fails the running `Playwright.Test` test at once, as
  upstream's worker fails and interrupts its current test on one (`workerMain.ts`
  `unhandledError`: "so that you can, e.g. expect() from inside an event handler"). Outside a
  test it is logged, as before; once the test ended it is printed.
  """
  alias Playwright.Test.Results
  alias Playwright.Test.TestInfo

  require Logger

  @doc "The calling process and its `$callers`: what a process started on its behalf gets."
  def capture, do: [self() | List.wrap(Process.get(:"$callers"))]

  @doc "Makes the calling process (one the client started for a callback) run on behalf of `callers`."
  def adopt(callers) do
    Process.put(:"$callers", callers)
    :ok
  end

  @doc "Runs `fun` after `adopt/1` (in a process the client started for the callback)."
  def run_as(callers, fun) do
    adopt(callers)
    fun.()
  end

  @doc "`fun` (1-arity), run on behalf of the calling process (`adopt/1`), wherever it is called."
  def bind_1(fun) do
    callers = capture()
    fn a -> run_as(callers, fn -> fun.(a) end) end
  end

  @doc "`fun` (2-arity), run on behalf of the calling process (`adopt/1`), wherever it is called."
  def bind_2(fun) do
    callers = capture()
    fn a, b -> run_as(callers, fn -> fun.(a, b) end) end
  end

  @doc """
  Whether the calling process runs on behalf of a `Playwright.Test` test past its own
  `on_exit` callbacks, whose contexts the runner closes: the test's process, and what it linked,
  are gone (#209), so its listeners no longer run.
  """
  def test_finished?, do: Results.finished?(List.wrap(Process.get(:"$callers")))

  @doc """
  An error nothing handled (JS: an uncaught exception or unhandled rejection): it fails and
  interrupts the running test of the `$callers` of the calling process
  (`Playwright.Test.TestInfo._unhandled_error/2`; printed once the test ended), else it is
  logged with `label`. In the test's own process (a local emitter's listener, run in place) it is
  raised there, as a sync listener's error is thrown to `emit`'s caller (`eventEmitter.ts`
  `_handleListenerError`).
  """
  def unhandled(label, kind, reason, stacktrace) do
    case TestInfo.current() do
      nil ->
        Logger.error(label <> Exception.format(kind, reason, stacktrace))

      %{test_pid: test_pid} when test_pid == self() ->
        :erlang.raise(kind, reason, stacktrace)

      test_info ->
        TestInfo._unhandled_error(test_info, {kind, Exception.normalize(kind, reason, stacktrace), stacktrace})
    end
  end
end
