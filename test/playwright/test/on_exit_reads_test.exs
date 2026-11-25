defmodule Playwright.Test.OnExitReadsTest do
  # A test's closed objects in an `on_exit` callback that runs after the test's end (registered
  # before `use Playwright.Test`, as a case template's own `setup` does), once the processes that
  # created or closed them have exited and their rows are freed: the closed-state getters answer
  # as after dispose, other reads raise.
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.BrowserType
  alias Playwright.Page
  alias Playwright.Runtime.Heap
  alias Playwright.Test.BrowserPool

  # The objects of each test, by test pid.
  setup_all do
    :ets.new(__MODULE__, [:public, :named_table])
    :ok
  end

  # Before the registration, so its `on_exit` runs after the test's end.
  setup _ctx do
    test_pid = self()

    on_exit(fn ->
      # Nothing to read when a setup failed first.
      with [{_, objects}] <- :ets.take(__MODULE__, test_pid) do
        await_freed(Map.values(objects))
        assert Page.is_closed(objects.page) == true
        assert BrowserContext.is_closed(objects.context) == true
        if browser = objects[:browser], do: assert(Browser.is_connected(browser) == false)
        assert_raise Playwright.TargetClosedError, fn -> Page.url(objects.page) end
      end
    end)
  end

  use Playwright.Test

  setup do
    context = Browser.new_context!(BrowserPool.browser())
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

  test "a browser the test closed", %{context: context, page: page} do
    browser = BrowserType.launch!(Browser.browser_type(BrowserPool.browser()))

    try do
      BrowserContext.new_page!(Browser.new_context!(browser))
      Browser.close!(browser)
      refute Browser.is_connected(browser)
    after
      if Browser.is_connected(browser), do: Browser.close!(browser)
    end

    :ets.insert(__MODULE__, {self(), %{context: context, page: page, browser: browser}})
  end

  # Until the processes the objects' rows are anchored to (that created or closed them) have
  # exited and their connection has freed the rows.
  defp await_freed(objects) do
    for %{guid: guid, table: table} <- objects do
      for pid <- :ets.select(table, [{{{guid, {:anchor, :"$1"}}, :_}, [], [:"$1"]}]) do
        await_exit(pid, guid)
      end
    end

    # The premise: their rows are gone. The Conn frees them on its own `:DOWN`, which may arrive
    # after ours, so poll.
    for object <- objects, do: await_unreadable(object, 500)
  end

  defp await_exit(pid, guid) when pid == self(),
    do: flunk("this on_exit process anchors #{inspect(guid)}; the test's premise no longer holds")

  defp await_exit(pid, _guid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
  end

  defp await_unreadable(object, 0), do: flunk("rows of #{inspect(object.guid)} were not freed within 5 s")

  defp await_unreadable(object, tries) do
    if Heap.readable?(object) do
      Process.sleep(10)
      await_unreadable(object, tries - 1)
    end
  end
end
