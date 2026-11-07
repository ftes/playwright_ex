defmodule PlaywrightEx.Library.BrowsercontextPagesTest do
  @upstream "tests/library/browsercontext-pages.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  import ExUnit.CaptureLog

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Utils

  test "BC-051 should not be visible in context.pages", %{context_factory: context_factory} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    assert page in BrowserContext.pages(context)
    Page.close!(page)
    refute page in BrowserContext.pages(context)
  end

  test "BC-052 page.context should return the correct instance", %{context_factory: context_factory} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    assert Page.context(page) == context
  end

  test "BC-053 frame.focus should work multiple times", %{context_factory: context_factory} do
    context = context_factory.([])
    page1 = BrowserContext.new_page!(context)
    page2 = BrowserContext.new_page!(context)

    for page <- [page1, page2] do
      Page.set_content!(page, ~s(<button id="foo" onfocus="window.gotFocus=true"></button>))
      Page.focus!(page, "#foo")
      assert Page.evaluate!(page, "() => !!window['gotFocus']") == true
    end
  end

  test "BC-054 should click with disabled javascript", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, java_script_enabled: false)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/wrappedlink.html")
    Page.expect_navigation!(page, fn -> Page.click!(page, "a") end)
    assert Page.url(page) == server.prefix <> "/wrappedlink.html#clicked"
    BrowserContext.close!(context)
  end

  test "BC-055 should not hang with touch-enabled viewports", %{browser: browser, playwright: playwright} do
    # @see https://github.com/GoogleChrome/puppeteer/issues/161
    %{viewport: viewport, has_touch: has_touch} = Playwright.devices(playwright)["iPhone 6"]
    context = Browser.new_context!(browser, viewport: viewport, has_touch: has_touch)
    page = BrowserContext.new_page!(context)
    Mouse.down!(Page.mouse(page))
    Mouse.move!(Page.mouse(page), 100, 10)
    Mouse.up!(Page.mouse(page))
    BrowserContext.close!(context)
  end

  test "BC-056 should click the button with deviceScaleFactor set", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, viewport: %{width: 400, height: 400}, device_scale_factor: 5)
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, "() => window.devicePixelRatio") == 5
    Page.set_content!(page, ~s(<div style="width:100px;height:100px">spacer</div>))
    Utils.attach_frame(page, "button-test", server.prefix <> "/input/button.html")
    frame = Enum.at(Page.frames(page), 1)
    button = Frame.query_selector!(frame, "button")
    ElementHandle.click!(button)
    assert Frame.evaluate!(frame, "() => window['result']") == "Clicked"
    BrowserContext.close!(context)
  end

  @tag skip: if(@browser_name == "firefox", do: "upstream skip: firefox (non-BiDi)")
  test "BC-057 should click the button with offset with page scale", %{
    browser: browser,
    server: server
  } do
    # it.skip(browserName === 'firefox' && !isBidi): we run Juggler Firefox.
    context = Browser.new_context!(browser, viewport: %{width: 400, height: 400}, is_mobile: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.eval_on_selector!(page, "button", """
    button => {
      button.style.borderWidth = '8px';
      document.body.style.margin = '0';
    }
    """)

    Page.click!(page, "button", position: %{x: 20, y: 10})
    assert Page.evaluate!(page, "result") == "Clicked"

    expect_close_to = fn expected, actual ->
      if abs(expected - actual) > 2, do: flunk("Expected: #{expected}, received: #{actual}")
    end

    # Expect 20;10 + 8px of border in each direction. Allow some delta as different
    # browsers round up or down differently during css -> dip -> css conversion.
    expect_close_to.(28, Page.evaluate!(page, "pageX"))
    expect_close_to.(18, Page.evaluate!(page, "pageY"))
    BrowserContext.close!(context)
  end

  @tag skip: if(@browser_name == "firefox", do: "upstream skip: firefox (non-BiDi)")
  test "BC-058 should return bounding box with page scale", %{browser: browser, server: server} do
    # it.skip(browserName === 'firefox' && !isBidi): we run Juggler Firefox.
    context = Browser.new_context!(browser, viewport: %{width: 400, height: 400}, is_mobile: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")

    JSHandle.evaluate!(button, """
    button => {
      document.body.style.margin = '0';
      button.style.borderWidth = '0';
      button.style.width = '200px';
      button.style.height = '20px';
      button.style.marginLeft = '17px';
      button.style.marginTop = '23px';
    }
    """)

    box = ElementHandle.bounding_box!(button)
    assert round(box.x * 100) == 17 * 100
    assert round(box.y * 100) == 23 * 100
    assert round(box.width * 100) == 200 * 100
    assert round(box.height * 100) == 20 * 100
    BrowserContext.close!(context)
  end

  # it.slow(true, 'We open 20 pages here!')
  @tag timeout: @slow_timeout
  test "BC-059 should not leak listeners during navigation of 20 pages", %{
    context_factory: context_factory,
    server: server
  } do
    context = context_factory.([])
    # process.on('warning', ...): the client's MaxListenersExceededWarning is logged here. Deviation:
    # no client emitter gets a second listener of one type in this scenario (the JS client's
    # neither); upstream catches the in-process server's warnings, ours go to the driver's stderr.
    # Promise.all has no timeout of its own: the test's.
    warning =
      capture_log(fn ->
        pages =
          1..20
          |> Enum.map(fn _ -> Task.async(fn -> BrowserContext.new_page!(context) end) end)
          |> Task.await_many(:infinity)

        pages
        |> Enum.map(fn page -> Task.async(fn -> Page.goto!(page, server.empty_page) end) end)
        |> Task.await_many(:infinity)

        pages
        |> Enum.map(fn page -> Task.async(fn -> Page.close!(page) end) end)
        |> Task.await_many(:infinity)
      end)

    refute warning =~ "MaxListenersExceededWarning"
  end

  @tag :page
  @tag skip:
         if(@browser_name == "chromium",
           do:
             "upstream fixme: Chromium loses the close when the reload commits into a new RenderFrameHost; fix is not rolled yet"
         )
  test "BC-060 should close page while a reload is committing", %{context: context} do
    # issue: https://github.com/microsoft/playwright/issues/42068
    # issue: https://issues.chromium.org/issues/536385539
    # it.fixme(browserName === 'chromium', 'Chromium loses the close when the reload commits into a new RenderFrameHost; fix is not rolled yet')
    # The evaluate never settles on its own, so it only rejects once the reload
    # commits. Closing right after that races the commit. Repeat a few times,
    # since whether the close or the commit wins is timing-dependent.
    for _ <- 1..10 do
      page = BrowserContext.new_page!(context)

      assert {:error, error} =
               Page.evaluate(page, """
               () => {
                 location.reload();
                 return new Promise(() => {});
               }
               """)

      assert Exception.message(error) =~ ~r/navigation/
      Page.close!(page)
    end
  end

  @tag :page
  test "BC-061 should keep selection in multiple pages", %{context: context} do
    # issue: https://github.com/microsoft/playwright/issues/27475
    page1 = BrowserContext.new_page!(context)
    page2 = BrowserContext.new_page!(context)

    for page <- [page1, page2] do
      Page.set_content!(page, ~s(<div id="container">lorem ipsum dolor sit amet</div>))

      Page.evaluate!(page, """
      () => {
        const element = document.getElementById('container');
        const textNode = element.firstChild;

        const range = document.createRange();
        range.setStart(textNode, 6);
        range.setEnd(textNode, 11);

        const selection = document.getSelection();
        selection?.removeAllRanges();
        selection?.addRange(range);
      }
      """)
    end

    # In WebKit, selection is updated via IPC, give it enough time to take effect.
    Process.sleep(1_000)

    for page <- [page1, page2] do
      range =
        Page.evaluate!(page, """
        () => {
          const selection = document.getSelection();
          const range = selection?.getRangeAt(0);
          return {
            rangeCount: selection?.rangeCount,
            startOffset: range?.startOffset,
            endOffset: range?.endOffset,
          };
        }
        """)

      assert range == %{"rangeCount" => 1, "startOffset" => 6, "endOffset" => 11}
    end
  end
end
