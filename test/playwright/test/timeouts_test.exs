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
  alias Playwright.Test.TestInfo
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

  if ExUnit.configuration()[:trace], do: @tag(skip: "mix test --trace has no timeouts")

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
  if ExUnit.configuration()[:trace], do: @tag(skip: "mix test --trace has no timeouts")

  test "a test that traps exits isn't interrupted: its contexts close with the timeout's reason, and a later one at its creation",
       ctx do
    page = BrowserContext.new_page!(Browser.new_context!(ctx.browser))
    recorder = Recorder.lookup(self())
    # The timer's message, as it fires (the timer itself cancelled; none under `--trace`).
    if timer = :sys.get_state(recorder).timer, do: Process.cancel_timer(timer)
    Process.flag(:trap_exit, true)
    send(recorder, :test_timeout)
    assert Recorder.timed_out?(recorder)

    # The call it hangs in fails with the reason and its call log.
    assert {:error, %Playwright.TargetClosedError{message: message}} = Page.wait_for_selector(page, "#never")
    reason = "Test timeout of #{Recorder.registration(self()).test_timeout}ms exceeded."
    assert message =~ reason
    refute_received {:EXIT, _, _}
    assert TestInfo.take_interrupt(self()) == nil

    message = "browser.newContext: " <> reason
    assert {:error, %Playwright.TargetClosedError{message: ^message}} = Browser.new_context(ctx.browser)

    # Closed, by its creator.
    %{contexts: [_first, late], closed: closed} = :sys.get_state(recorder)
    assert late.guid in closed
  end

  test "the timeout doesn't interrupt a test another interrupt stopped" do
    Process.flag(:trap_exit, true)
    test = Recorder.registration(self())
    assert TestInfo._unhandled_error(test, {:error, RuntimeError.exception("first"), []})
    assert_receive {:EXIT, _, {%RuntimeError{message: "first"}, []}}
    assert TestInfo._time_out(test, {:error, %TimeoutManagerError{message: "late"}, []}) == :dropped
    refute_received {:EXIT, _, _}
    assert {_exit_reason, {:error, %RuntimeError{}, []}} = TestInfo.take_interrupt(self())
  end

  test "the error of a call whose caller exited goes to its adopter, with the API name: a call of the test's Task too",
       ctx do
    context = Browser.new_context!(ctx.browser)
    page = BrowserContext.new_page!(context)
    connection = Heap.get(context, :_connection)
    pending = Connection.callbacks(connection)
    # A dead process stands for the test, its `Task` for the caller.
    test = spawn(fn -> :ok end)

    test_pid = self()

    [{caller, ref}, _live] =
      for selector <- ["#never", "#never-live"] do
        spawn_monitor(fn ->
          Process.put(:"$callers", [test])
          send(test_pid, {:live, Page.wait_for_selector(page, selector)})
        end)
      end

    # The first interrupted in its call, as at the test timeout.
    wait_until(fn -> length(Connection.callbacks(connection) -- pending) == 2 end)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    Connection._adopt_calls(connection, test, &send(test_pid, {:late, &1}))
    BrowserContext.close!(context, reason: "Test timeout of 1ms exceeded.")
    assert_receive {:late, %Playwright.TargetClosedError{message: message, log: [_ | _]}}
    assert message =~ ~r"^page\.waitForSelector: Test timeout of 1ms exceeded\.\nCall log:\n.*#never'"
    # Not the live caller's: it gets its own.
    assert_receive {:live, {:error, %Playwright.TargetClosedError{message: live}}}
    assert live =~ "#never-live"
    refute_received {:late, _}
  end

  test "a caller whose exit is on its way is adopted too: a call of a reported zone gets the zone's API name",
       ctx do
    context = Browser.new_context!(ctx.browser)
    page = BrowserContext.new_page!(context)
    connection = Heap.get(context, :_connection)
    pending = Connection.callbacks(connection)
    test_pid = self()

    # Alive, in a call that isn't its zone's first (internal): the zone's name is its prefix.
    caller =
      spawn(fn ->
        Playwright.Runtime.Facade.call("page.composite", fn ->
          Playwright.Client.ChannelOwner._wrap_api_call(page, fn _zone ->
            Page.title(page)
            Page.wait_for_selector(page, "#never")
          end)
        end)
      end)

    wait_until(fn -> length(Connection.callbacks(connection) -- pending) == 1 end)
    assert [_id] = Connection._adopt_calls(connection, caller, &send(test_pid, {:late, &1}), %{dying: [caller]})
    Process.exit(caller, :kill)
    BrowserContext.close!(context, reason: "Test timeout of 1ms exceeded.")
    assert_receive {:late, %Playwright.TargetClosedError{message: message}}, 5000
    assert message =~ ~r"^page\.composite: Test timeout of 1ms exceeded\.\nCall log:"
  end

  test "a context created for a test that exited at its timeout is closed when it comes", ctx do
    error = %TimeoutManagerError{message: "Test timeout of 1ms exceeded.", late_error: make_ref()}
    on_exit(fn -> :ets.delete(Results.table(), {:late_error, error.late_error}) end)
    connection = Heap.get(ctx.browser, :_connection)
    before = Browser.contexts(ctx.browser)

    # The creation adopted while it waits for its reply (a few tries: the reply may come first),
    # its caller then exiting, as at the interrupt.
    adopted =
      Enum.find_value(1..20, fn _ ->
        pending = Connection.callbacks(connection)
        caller = spawn(fn -> Browser.new_context(ctx.browser) end)
        spin_until(fn -> Connection.callbacks(connection) -- pending != [] or not Process.alive?(caller) end)
        adopted = Recorder.adopt_calls([], caller, error, Recorder.dying(caller))
        Process.exit(caller, :kill)
        # Too late: the caller's own, closed here.
        if adopted == [], do: for(late <- Browser.contexts(ctx.browser) -- before, do: BrowserContext.close(late))
        adopted != [] and adopted
      end)

    assert [{^connection, [_id]}] = adopted
    wait_until(fn -> Browser.contexts(ctx.browser) == before end)
  end

  test "the timeout's message ends with the call's error, once it came" do
    error = %TimeoutManagerError{message: "Test timeout of 1ms exceeded.", late_error: make_ref()}
    assert Exception.message(error) == "Test timeout of 1ms exceeded."

    TimeoutManagerError.put_late_error(error, %Playwright.TimeoutError{message: "page.click: late"})
    TimeoutManagerError.put_late_error(error, %Playwright.TimeoutError{message: "page.click: later"})
    assert Exception.message(error) == "Test timeout of 1ms exceeded.\n\n** (Playwright.TimeoutError) page.click: late"
    :ets.delete(Results.table(), {:late_error, error.late_error})
  end

  defp spin_until(fun), do: if(!fun.(), do: spin_until(fun))

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
  if ExUnit.configuration()[:trace], do: @tag(skip: "mix test --trace has no timeouts")

  test "the deadline is ExUnit's: from the first setup callback" do
    assert Recorder.registration(self()).deadline - System.monotonic_time(:millisecond) <= 10_000 - 300
  end
end
