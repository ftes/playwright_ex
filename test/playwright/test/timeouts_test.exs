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
  alias Playwright.Page
  alias Playwright.Runtime.Heap
  alias Playwright.Test.BrowserPool
  alias Playwright.Test.Recorder

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
    # The timer's message, as it fires (the timer itself cancelled; none under `--trace`).
    if timer = :sys.get_state(recorder).timer, do: Process.cancel_timer(timer)
    send(recorder, :test_timeout)
    assert Recorder.timed_out?(recorder)

    message = "browser.newContext: Test timeout of #{Recorder.registration(self()).test_timeout}ms exceeded."
    assert {:error, %Playwright.TargetClosedError{message: ^message}} = Browser.new_context(ctx.browser)

    # Closed, by its creator.
    %{contexts: [_first, late], closed: closed} = :sys.get_state(recorder)
    assert late.guid in closed

    # `Browser.new_page` creates its context the same way.
    message = "browser.newPage: Test timeout of #{Recorder.registration(self()).test_timeout}ms exceeded."
    assert {:error, %Playwright.TargetClosedError{message: ^message}} = Browser.new_page(ctx.browser)
  end

  test "the timer closes a context whose setup hasn't ended", ctx do
    Browser.new_context!(ctx.browser)
    recorder = Recorder.lookup(self())
    if timer = :sys.get_state(recorder).timer, do: Process.cancel_timer(timer)

    # A context registered, its setup (`record/3`) still running: created outside the test, it
    # has no setup of its own. Its creator stays, as a test's process does, linked so it ends with
    # the test.
    me = self()

    spawn_link(fn ->
      send(me, {:context, Browser.new_context!(ctx.browser)})
      Process.sleep(:infinity)
    end)

    assert_receive {:context, context}
    :ok = GenServer.call(recorder, {:add_context, context})
    BrowserContext.on(context, :close, fn _ -> send(me, :closed) end)

    send(recorder, :test_timeout)
    assert_receive :closed, 5000
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
