defmodule Playwright.Test.OnExitReadsTest do
  # A passing test's closed objects in an `on_exit` callback that runs after the test's end
  # (registered before `use Playwright.Test`, as a case template's own `setup` does), once every
  # process that created them has exited: they read their last values, as the connection retains
  # them (a failed test's: `Playwright.Test.EndToEndTest`, `late_reads`). A driver of its own,
  # recorded as the pool's are, so other tests' closes on a shared connection never push these
  # out of its cap (`Playwright.Runtime.Conn.trim/2`).
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.BrowserType
  alias Playwright.Client.ClientInstrumentation
  alias Playwright.Page
  alias Playwright.Runtime.Heap
  alias Playwright.Test.Recorder
  alias Playwright.TestBrowser

  # The objects of each test, by test pid, and the browser.
  setup_all do
    :ets.new(__MODULE__, [:public, :named_table])
    name = __MODULE__.Driver
    start_supervised!({Playwright.Supervisor, name: name})
    playwright = Playwright.instance(name)
    ClientInstrumentation.add_listener(Heap.get(playwright, :_instrumentation), Recorder.listener())
    %{browser: BrowserType.launch!(TestBrowser.browser_type(playwright), headless: TestBrowser.headless())}
  end

  # Before the registration, so its `on_exit` runs after the test's end.
  setup _ctx do
    test_pid = self()

    on_exit(fn ->
      # Nothing to read when a setup failed first.
      with [{_, objects}] <- :ets.take(__MODULE__, test_pid) do
        await_creators(Map.values(objects))
        assert Page.is_closed(objects.page) == true
        assert BrowserContext.is_closed(objects.context) == true
        if browser = objects[:browser], do: assert(Browser.is_connected(browser) == false)
        assert Page.url(objects.page) == "about:blank"
        assert BrowserContext.pages(objects.context) == []
        assert Page.context(objects.page) == objects.context
      end
    end)
  end

  use Playwright.Test

  setup %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    :ets.insert(__MODULE__, {self(), %{context: context, page: page}})
    %{context: context, page: page}
  end

  test "a context left open, closed by the test's end", %{page: page} do
    refute Page.is_closed(page)
  end

  test "a context the test closed", %{context: context, page: page} do
    BrowserContext.close!(context)
    assert Page.is_closed(page)
  end

  test "a browser the test closed", %{browser: own, context: context, page: page} do
    browser = BrowserType.launch!(Browser.browser_type(own), headless: TestBrowser.headless())

    try do
      BrowserContext.new_page!(Browser.new_context!(browser))
      Browser.close!(browser)
      refute Browser.is_connected(browser)
    after
      if Browser.is_connected(browser), do: Browser.close!(browser)
    end

    :ets.insert(__MODULE__, {self(), %{context: context, page: page, browser: browser}})
  end

  # The premise: the processes that created them have exited.
  defp await_creators(objects) do
    for object <- objects, pid <- Heap.get(object, :_creators) || [], pid != self() do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
    end
  end
end
