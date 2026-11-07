defmodule PlaywrightEx.Library.EmulationFocusTest do
  @upstream "tests/library/emulation-focus.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page

  import PlaywrightEx.UpstreamSnapshot
  import PlaywrightEx.Utils, only: [attach_frame: 3]

  @moduletag :page

  # Promise.all([...])
  defp all(funs), do: funs |> Enum.map(&Task.async/1) |> Task.await_many(:infinity)

  test "EM-013 should think that it is focused by default", %{page: page} do
    assert Page.evaluate!(page, "document.hasFocus()") == true
  end

  test "EM-014 should think that all pages are focused @smoke", %{page: page} do
    page2 = BrowserContext.new_page!(Page.context(page))
    assert Page.evaluate!(page, "document.hasFocus()") == true
    assert Page.evaluate!(page2, "document.hasFocus()") == true
    Page.close!(page2)
  end

  test "EM-015 should focus popups by default", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "url => { window.open(url); }", server.empty_page) end)
    assert Page.evaluate!(popup, "document.hasFocus()") == true
    assert Page.evaluate!(page, "document.hasFocus()") == true
  end

  test "EM-016 should provide target for keyboard events", %{page: page, server: server} do
    page2 = BrowserContext.new_page!(Page.context(page))

    all([
      fn -> Page.goto!(page, server.prefix <> "/input/textarea.html") end,
      fn -> Page.goto!(page2, server.prefix <> "/input/textarea.html") end
    ])

    all([fn -> Page.focus!(page, "input") end, fn -> Page.focus!(page2, "input") end])
    text = "first"
    text2 = "second"

    all([
      fn -> Keyboard.type!(Page.keyboard(page), text) end,
      fn -> Keyboard.type!(Page.keyboard(page2), text2) end
    ])

    results = all([fn -> Page.evaluate!(page, "result") end, fn -> Page.evaluate!(page2, "result") end])
    assert results == [text, text2]
  end

  test "EM-017 should not affect mouse event target page", %{page: page} do
    page2 = BrowserContext.new_page!(Page.context(page))

    click_counter = """
    function clickCounter() {
      document.onclick = () => window['clickCount']  = (window['clickCount'] || 0) + 1;
    }
    """

    all([
      fn -> Page.evaluate!(page, click_counter) end,
      fn -> Page.evaluate!(page2, click_counter) end,
      fn -> Page.focus!(page, "body") end,
      fn -> Page.focus!(page2, "body") end
    ])

    all([fn -> Mouse.click!(Page.mouse(page), 1, 1) end, fn -> Mouse.click!(Page.mouse(page2), 1, 1) end])

    counters =
      all([fn -> Page.evaluate!(page, "window.clickCount") end, fn -> Page.evaluate!(page2, "window.clickCount") end])

    assert counters == [1, 1]
  end

  test "EM-018 should change document.activeElement", %{page: page, server: server} do
    page2 = BrowserContext.new_page!(Page.context(page))

    all([
      fn -> Page.goto!(page, server.prefix <> "/input/textarea.html") end,
      fn -> Page.goto!(page2, server.prefix <> "/input/textarea.html") end
    ])

    all([fn -> Page.focus!(page, "input") end, fn -> Page.focus!(page2, "textarea") end])

    active =
      all([
        fn -> Page.evaluate!(page, "document.activeElement.tagName") end,
        fn -> Page.evaluate!(page2, "document.activeElement.tagName") end
      ])

    assert active == ["INPUT", "TEXTAREA"]
  end

  test "EM-019 should not affect screenshots", %{page: page, server: server} do
    # it.skip(browserName === 'webkit' && isWindows && !headless)  -- headless here
    # it.skip(browserName === 'webkit' && isLinux && !headless)  -- headless here
    # it.skip(browserName === 'firefox' && !headless)  -- headless here
    page2 = BrowserContext.new_page!(Page.context(page))

    Task.await_many(
      [
        Task.async(fn -> Page.set_viewport_size!(page, %{width: 500, height: 500}) end),
        Task.async(fn -> Page.goto!(page, server.prefix <> "/grid.html") end),
        Task.async(fn -> Page.set_viewport_size!(page2, %{width: 50, height: 50}) end),
        Task.async(fn -> Page.goto!(page2, server.prefix <> "/grid.html") end)
      ],
      :infinity
    )

    Task.await_many(
      [
        Task.async(fn -> Page.focus!(page, "body") end),
        Task.async(fn -> Page.focus!(page2, "body") end)
      ],
      :infinity
    )

    screenshots =
      Task.await_many(
        [
          Task.async(fn -> Page.screenshot!(page) end),
          Task.async(fn -> Page.screenshot!(page2) end)
        ],
        :infinity
      )

    to_match_snapshot(Enum.at(screenshots, 0), "screenshot-sanity.png")
    to_match_snapshot(Enum.at(screenshots, 1), "grid-cell-0.png")
  end

  test "EM-020 should change focused iframe", %{page: page, server: server} do
    # it.skip(browserName === 'firefox' && !headless, 'Headed FF might lose focus'): we run headless
    Page.goto!(page, server.empty_page)

    [frame1, frame2] =
      all([
        fn -> attach_frame(page, "frame1", server.prefix <> "/input/textarea.html") end,
        fn -> attach_frame(page, "frame2", server.prefix <> "/input/textarea.html") end
      ])

    logger = """
    function logger() {
      self['_events'] = [];
      const element = document.querySelector('input');
      element.onfocus = element.onblur = e => self['_events'].push(e.type);
    }
    """

    all([fn -> Frame.evaluate!(frame1, logger) end, fn -> Frame.evaluate!(frame2, logger) end])

    focused = all([fn -> has_focus(frame1) end, fn -> has_focus(frame2) end])
    assert focused == [false, false]

    Frame.focus!(frame1, "input")
    events = all([fn -> Frame.evaluate!(frame1, "self._events") end, fn -> Frame.evaluate!(frame2, "self._events") end])
    assert events == [["focus"], []]
    focused = all([fn -> has_focus(frame1) end, fn -> has_focus(frame2) end])
    assert focused == [true, false]

    Frame.focus!(frame2, "input")
    events = all([fn -> Frame.evaluate!(frame1, "self._events") end, fn -> Frame.evaluate!(frame2, "self._events") end])
    assert events == [["focus", "blur"], ["focus"]]
    focused = all([fn -> has_focus(frame1) end, fn -> has_focus(frame2) end])
    assert focused == [false, true]
  end

  # @see https://github.com/microsoft/playwright/issues/3476
  test "EM-021 should focus with more than one page/context", %{context_factory: context_factory} do
    page1 = BrowserContext.new_page!(context_factory.([]))
    page2 = BrowserContext.new_page!(context_factory.([]))
    Page.set_content!(page1, ~s(<button id="foo" onfocus="window.gotFocus=true">foo</button>))
    Page.set_content!(page2, ~s(<button id="foo" onfocus="window.gotFocus=true">foo</button>))
    Page.focus!(page1, "#foo")
    Page.focus!(page2, "#foo")
    assert Page.evaluate!(page1, "() => !!window['gotFocus']") == true
    assert Page.evaluate!(page2, "() => !!window['gotFocus']") == true
  end

  test "EM-022 should not fire blur events when interacting with more than one page/context", %{
    context_factory: context_factory
  } do
    # annotation: https://github.com/microsoft/playwright/issues/30399
    page1 = BrowserContext.new_page!(context_factory.([]))
    page2 = BrowserContext.new_page!(context_factory.([]))
    Page.set_content!(page1, ~s(<button id="foo" onblur="window.gotBlur=true">foo</button>))
    Page.set_content!(page2, ~s(<button id="foo" onblur="window.gotBlur=true">foo</button>))
    Page.click!(page1, "#foo")
    Page.click!(page2, "#foo")
    assert Page.evaluate!(page1, "() => !!window['gotBlur']") == false
    assert Page.evaluate!(page2, "() => !!window['gotBlur']") == false
  end

  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: https://github.com/microsoft/playwright/issues/43280")
  test "EM-023 should not blur iframe when interacting with another page/context", %{context_factory: context_factory} do
    # annotation: https://github.com/microsoft/playwright/issues/42933
    page1 = BrowserContext.new_page!(context_factory.([]))
    page2 = BrowserContext.new_page!(context_factory.([]))
    srcdoc = "<button id=foo>foo</button><script>window.addEventListener('blur', () => window.gotBlur = true)</script>"
    Page.set_content!(page1, ~s(<iframe srcdoc="#{srcdoc}"></iframe><iframe srcdoc="#{srcdoc}"></iframe>))
    [_, frame1, frame2] = Page.frames(page1)
    Frame.click!(frame1, "#foo")
    Page.set_content!(page2, "<p>other page</p>")
    Mouse.click!(Page.mouse(page2), 10, 10)
    assert Frame.evaluate!(frame1, "() => !!window['gotBlur']") == false
    assert Frame.evaluate!(frame1, "() => document.hasFocus()") == true
    assert Frame.evaluate!(frame2, "() => document.hasFocus()") == false
  end

  test "EM-024 should trigger hover state concurrently", %{browser_type: browser_type} do
    # annotation: https://github.com/microsoft/playwright/issues/27969
    # browserTest.skip(!headless, 'headed messes up with hover'): we run headless
    browser1 = BrowserType.launch!(browser_type)
    context1 = Browser.new_context!(browser1)
    page1 = BrowserContext.new_page!(context1)
    page2 = BrowserContext.new_page!(context1)
    browser2 = BrowserType.launch!(browser_type)
    page3 = Browser.new_page!(browser2)

    for page <- [page1, page2, page3] do
      Page.set_content!(page, """
        <style>
          button { display: none; }
          div:hover button { display: inline };
        </style>
        <div><span>hover me</span><button onclick="window.clicked=1+(window.clicked || 0)">click me</button></div>
      """)
    end

    for page <- [page1, page2, page3], do: Page.hover!(page, "span")
    for page <- [page1, page2, page3], do: Page.click!(page, "button")
    for page <- [page1, page2, page3], do: assert(Page.evaluate!(page, "window.clicked") == 1)
    for page <- [page1, page2, page3], do: Page.click!(page, "button")
    for page <- [page1, page2, page3], do: assert(Page.evaluate!(page, "window.clicked") == 2)
    # Upstream leaves the browsers to the worker teardown.
    Browser.close!(browser1)
    Browser.close!(browser2)
  end

  defp has_focus(frame), do: Frame.evaluate!(frame, "document.hasFocus()")
end
