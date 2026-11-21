defmodule Playwright.Test.TimeoutsTest do
  # Playwright Test's `actionTimeout`/`navigationTimeout` (none by default) on each context of the
  # test, and the test timeout's timer in its recorder. The timeout's closes and errors:
  # `Playwright.Test.EndToEndTest`.
  use ExUnit.Case, async: true
  use Playwright.Test

  alias Playwright.APIRequest
  alias Playwright.APIRequestContext
  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Client.Connection
  alias Playwright.Page
  alias Playwright.Runtime.Heap
  alias Playwright.Test.BrowserPool
  alias Playwright.Test.Recorder
  alias Playwright.Test.Results
  alias Playwright.Test.TimeoutManagerError

  setup_all do
    browser = BrowserPool.browser()
    %{browser: browser, playwright: BrowserPool.playwright(browser)}
  end

  defp defaults(owner) do
    settings = Heap.get(owner, :_timeoutSettings)
    {Heap.get(settings, :_defaultTimeout), Heap.get(settings, :_defaultNavigationTimeout)}
  end

  test "each context gets no action and navigation timeout by default, upstream's 0", ctx do
    assert defaults(Browser.new_context!(ctx.browser)) == {0, 0}
    assert defaults(Task.await(Task.async(fn -> Browser.new_context!(ctx.browser) end))) == {0, 0}

    request = APIRequest.new_context!(Playwright.request(ctx.playwright))
    assert {0, nil} = defaults(request)
    APIRequestContext.dispose!(request)

    # The Playwright's defaults stay as they were: the driver outlives the test.
    assert Heap.get(ctx.playwright, :_defaultContextTimeout) == nil

    # A context's own setting wins.
    context = Browser.new_context!(ctx.browser)
    BrowserContext.set_default_timeout(context, 100)
    page = BrowserContext.new_page!(context)

    assert {:error, %{message: "page.waitForSelector: Timeout 100ms exceeded." <> _}} =
             Page.wait_for_selector(page, "#x")
  end

  test "a test with a timeout arms its recorder's timer, 1 s or 5% before it", ctx do
    Browser.new_context!(ctx.browser)
    assert is_reference(:sys.get_state(Recorder.lookup(self())).timer)
    assert Recorder.test_timeout_margin(60_000) == 1000
    assert Recorder.test_timeout_margin(3000) == 150
  end

  test "the timer firing after the test exited, before its DOWN, closes nothing" do
    test_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    tmp = Path.join(System.tmp_dir!(), "recorder-#{System.unique_integer([:positive])}")
    deadline = System.monotonic_time(:millisecond) + 60_000

    {:ok, recorder} =
      GenServer.start(Recorder, %{test_pid: test_pid, deadline: deadline, test_timeout: 60_000, tmp: tmp})

    # The timer's message, then the test's DOWN, in the recorder's mailbox.
    :sys.suspend(recorder)
    send(recorder, :test_timeout)
    ref = Process.monitor(test_pid)
    send(test_pid, :stop)
    assert_receive {:DOWN, ^ref, :process, _, _}
    :sys.resume(recorder)

    refute Recorder.timed_out?(recorder)
    GenServer.stop(recorder)
  end

  @tag timeout: 30_000
  test "a context created after the timer fired is closed, its creation fails with the timeout's reason",
       ctx do
    Browser.new_context!(ctx.browser)
    recorder = Recorder.lookup(self())
    # The timer's message, as it fires (the timer itself cancelled; none under `--trace`): its
    # interrupt received, not exited by, and taken back.
    if timer = :sys.get_state(recorder).timer, do: Process.cancel_timer(timer)
    Process.flag(:trap_exit, true)
    send(recorder, :test_timeout)
    assert_receive {:EXIT, _, {%TimeoutManagerError{message: "Test timeout of 30000ms exceeded."}, [_ | _]}}
    assert {_exit_reason, _error} = Playwright.Test.TestInfo.take_interrupt(self())
    assert Recorder.timed_out?(recorder)

    message = "browser.newContext: Test timeout of #{Recorder.registration(self()).test_timeout}ms exceeded."
    assert {:error, %Playwright.TargetClosedError{message: ^message}} = Browser.new_context(ctx.browser)

    # Closed, by its creator.
    %{contexts: [_first, late], closed: closed} = :sys.get_state(recorder)
    assert late.guid in closed
  end

  test "the error of a call whose caller exited goes to its adopter, with the API name", ctx do
    context = Browser.new_context!(ctx.browser)
    page = BrowserContext.new_page!(context)
    connection = Heap.get(context, :_connection)
    pending = Connection.callbacks(connection)
    {caller, ref} = spawn_monitor(fn -> Page.wait_for_selector(page, "#never") end)

    # Interrupted in the call, as at the test timeout.
    wait_until(fn -> Connection.callbacks(connection) -- pending != [] end)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    test_pid = self()
    Connection._adopt_calls(connection, caller, &send(test_pid, {:late, &1}))
    BrowserContext.close!(context, reason: "Test timeout of 1ms exceeded.")
    assert_receive {:late, %Playwright.TargetClosedError{message: message, log: [_ | _]}}
    assert message =~ ~r"^page\.waitForSelector: Test timeout of 1ms exceeded\.\nCall log:\n"
  end

  test "the timeout's message ends with the call's error, once it came" do
    error = %TimeoutManagerError{message: "Test timeout of 1ms exceeded.", late_error: make_ref()}
    assert Exception.message(error) == "Test timeout of 1ms exceeded."

    TimeoutManagerError.put_late_error(error, %Playwright.TimeoutError{message: "page.click: late"})
    TimeoutManagerError.put_late_error(error, %Playwright.TimeoutError{message: "page.click: later"})
    assert Exception.message(error) == "Test timeout of 1ms exceeded.\n\n** (Playwright.TimeoutError) page.click: late"
    :ets.delete(Results.table(), {:late_error, error.late_error})
  end

  defp wait_until(fun) do
    if !fun.() do
      Process.sleep(10)
      wait_until(fun)
    end
  end

  @tag timeout: :infinity
  test "a test without a timeout has no timer", ctx do
    Browser.new_context!(ctx.browser)
    assert :sys.get_state(Recorder.lookup(self())).timer == nil
  end
end

defmodule Playwright.Test.TimeoutsSlowSetupTest do
  # The test's deadline counts the setup callbacks before `use Playwright.Test`'s, as ExUnit's
  # timeout does.
  use ExUnit.Case, async: true

  alias Playwright.Test.Recorder

  setup do
    Process.sleep(300)
  end

  use Playwright.Test

  @tag timeout: 10_000
  test "the deadline is ExUnit's: from the first setup callback" do
    assert Recorder.registration(self()).deadline - System.monotonic_time(:millisecond) <= 10_000 - 300
  end
end
