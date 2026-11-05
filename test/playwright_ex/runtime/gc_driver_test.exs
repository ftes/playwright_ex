defmodule PlaywrightEx.Runtime.GCDriverTest do
  # Row counts of the driver's shared heaps: no other test may use this driver.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.GC
  alias PlaywrightEx.TestBrowser

  @moduletag timeout: 300_000

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    browser = BrowserType.launch!(TestBrowser.browser_type(PlaywrightEx.playwright(__MODULE__)))
    %{browser: browser}
  end

  setup %{browser: browser} do
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close(context) end)
    %{page: BrowserContext.new_page!(context)}
  end

  defp rows(page), do: :ets.info(page.loop.heap, :size) + :ets.info(page.heap, :size)

  defp collect(page) do
    EventLoop.with_baton(page.loop, fn -> GC.collect(page.loop) end)
    EventLoop.with_baton(page.loop, fn -> GC.collect(page.loop) end)
  end

  test "1000 evaluate calls leave the heap bounded", %{page: page} do
    Page.evaluate!(page, "1")
    collect(page)
    baseline = rows(page)

    sizes =
      for _ <- 1..1000 do
        Page.evaluate!(page, "1")
        rows(page)
      end

    # Collections run every 2000 allocations at least (one promise per call).
    assert Enum.max(sizes) < baseline + 4100
    collect(page)
    assert rows(page) <= baseline + 10
  end

  @tag skip:
         if(TestBrowser.name() == "firefox" and match?({:unix, :linux}, :os.type()),
           do:
             "env: Linux firefox (CI runner, with or without xvfb) stops answering newPage after ~100 pages; passes on macOS"
         )
  test "opening and closing pages reaches a steady state", %{browser: browser, page: page} do
    open_close = fn n ->
      for _ <- 1..n do
        context = Browser.new_context!(browser)
        context |> BrowserContext.new_page!() |> Page.goto!("data:text/html,<p>hi</p>")
        BrowserContext.close!(context)
      end

      collect(page)
      rows(page)
    end

    # Closed objects stay readable among the last 500 disposed (a few per page), then go.
    first = open_close.(100)
    second = open_close.(100)
    assert second <= first * 1.1
    assert second < 20_000
  end

  test "a wait handle is awaitable after it settled and was collected", %{page: page} do
    console = Page.wait_for_event(page, :console)
    Page.evaluate!(page, "console.log('hi')")
    collect(page)
    assert {:ok, message} = PlaywrightEx.Promise.await(console)
    assert PlaywrightEx.ConsoleMessage.text(message) == "hi"
    assert {:ok, ^message} = PlaywrightEx.Promise.await(console)
  end

  # The connection heap grows by the messages' live JSHandles, as in JS (the server disposes them).
  test "the callback form of a wait does not keep its handle", %{page: page} do
    collect(page)
    baseline = :ets.info(page.loop.heap, :size)

    for _ <- 1..200 do
      Page.expect_console_message!(page, fn -> Page.evaluate!(page, "console.log('hi')") end)
    end

    collect(page)
    assert :ets.select_count(page.loop.roots, [{{{{:returned, self()}, :_}, :_}, [], [true]}]) == 0
    assert :ets.info(page.loop.heap, :size) <= baseline + 10
  end
end
