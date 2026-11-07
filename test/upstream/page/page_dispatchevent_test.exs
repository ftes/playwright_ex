defmodule PlaywrightEx.Page.PageDispatcheventTest do
  @upstream "tests/page/page-dispatchevent.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.Selectors
  alias PlaywrightEx.Utils

  @moduletag :page

  test "DE-001 should dispatch click event @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.dispatch_event!(page, "button", "click")
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  test "DE-002 should dispatch click event properties", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.dispatch_event!(page, "button", "click")
    Utils.assert_truthy(Page.evaluate!(page, "bubbles"))
    Utils.assert_truthy(Page.evaluate!(page, "cancelable"))
    Utils.assert_truthy(Page.evaluate!(page, "composed"))
  end

  test "DE-003 should dispatch click svg", %{page: page} do
    Page.set_content!(page, """
    <svg height="100" width="100">
      <circle onclick="javascript:window.__CLICKED=42" cx="50" cy="50" r="40" stroke="black" stroke-width="3" fill="red" />
    </svg>
    """)

    Page.dispatch_event!(page, "circle", "click")
    assert Page.evaluate!(page, "() => window['__CLICKED']") == 42
  end

  test "DE-004 should dispatch click on a span with an inline element inside", %{page: page} do
    Page.set_content!(page, """
    <style>
    span::before {
      content: 'q';
    }
    </style>
    <span onclick='javascript:window.CLICKED=42'></span>
    """)

    Page.dispatch_event!(page, "span", "click")
    assert Page.evaluate!(page, "() => window['CLICKED']") == 42
  end

  test "DE-005 should dispatch click after navigation ", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.dispatch_event!(page, "button", "click")
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.dispatch_event!(page, "button", "click")
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  test "DE-006 should dispatch click after a cross origin navigation ", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.dispatch_event!(page, "button", "click")
    Page.goto!(page, server.cross_process_prefix <> "/input/button.html")
    Page.dispatch_event!(page, "button", "click")
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  test "DE-007 should not fail when element is blocked on hover", %{page: page} do
    Page.set_content!(page, """
    <style>
      container { display: block; position: relative; width: 200px; height: 50px; }
      div, button { position: absolute; left: 0; top: 0; bottom: 0; right: 0; }
      div { pointer-events: none; }
      container:hover div { pointer-events: auto; background: red; }
    </style>
    <container>
      <button onclick="window.clicked=true">Click me</button>
      <div></div>
    </container>
    """)

    Page.dispatch_event!(page, "button", "click")
    Utils.assert_truthy(Page.evaluate!(page, "() => window['clicked']"))
  end

  test "DE-008 should dispatch click when node is added in shadow dom", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    watchdog = Runtime.Promise.async(fn -> Page.dispatch_event!(page, "span", "click") end)

    Page.evaluate!(page, """
    () => {
      const div = document.createElement('div');
      div.attachShadow({ mode: 'open' });
      document.body.appendChild(div);
    }
    """)

    Page.wait_for_timeout!(page, 100)

    Page.evaluate!(page, """
    () => {
      const span = document.createElement('span');
      span.textContent = 'Hello from shadow';
      span.addEventListener('click', () => window['clicked'] = true);
      document.querySelector('div').shadowRoot.appendChild(span);
    }
    """)

    Runtime.Promise.await(watchdog)
    assert Page.evaluate!(page, "() => window['clicked']") == true
  end

  test "DE-009 should be atomic", %{playwright: playwright, page: page} do
    create_dummy_selector = """
    (() => ({
      query(root, selector) {
        const result = root.querySelector(selector);
        if (result)
          void Promise.resolve().then(() => result.onclick = '');
        return result;
      },
      queryAll(root, selector) {
        const result = Array.from(root.querySelectorAll(selector));
        for (const e of result)
          void Promise.resolve().then(() => e.onclick = null);
        return result;
      }
    }))()
    """

    Selectors.register!(Playwright.selectors(playwright), "dispatchEvent", create_dummy_selector)
    Page.goto!(page, ~s|data:text/html,<div onclick="window._clicked=true">Hello</div>|)
    Page.dispatch_event!(page, "dispatchEvent=div", "click")
    assert Page.evaluate!(page, "() => window['_clicked']") == true
  end

  test "DE-010 should dispatch drag drop events", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/drag-n-drop.html")
    data_transfer = Page.evaluate_handle!(page, "() => new DataTransfer()")
    Page.dispatch_event!(page, "#source", "dragstart", %{dataTransfer: data_transfer})
    Page.dispatch_event!(page, "#target", "drop", %{dataTransfer: data_transfer})
    source = Page.query_selector!(page, "#source")
    target = Page.query_selector!(page, "#target")

    Utils.assert_truthy(
      Page.evaluate!(
        page,
        "({ source, target }) => { return source.parentElement === target; }",
        %{source: source, target: target}
      )
    )
  end

  test "DE-011 should dispatch drag drop events via ElementHandles", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/drag-n-drop.html")
    data_transfer = Page.evaluate_handle!(page, "() => new DataTransfer()")
    source = Page.query_selector!(page, "#source")
    ElementHandle.dispatch_event!(source, "dragstart", %{dataTransfer: data_transfer})
    target = Page.query_selector!(page, "#target")
    ElementHandle.dispatch_event!(target, "drop", %{dataTransfer: data_transfer})

    Utils.assert_truthy(
      Page.evaluate!(
        page,
        "({ source, target }) => { return source.parentElement === target; }",
        %{source: source, target: target}
      )
    )
  end

  test "DE-012 should dispatch click event via ElementHandles", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")
    ElementHandle.dispatch_event!(button, "click")
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  # https://github.com/microsoft/playwright/issues/15562
  test "DE-013 should dispatch wheel event", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")

    events_handle =
      page
      |> Page.locator("body")
      |> Locator.evaluate_handle!("""
      e => {
        const events = [];
        e.addEventListener('wheel', event => {
          events.push(event);
          console.log(event);
        });
        return events;
      }
      """)

    Locator.dispatch_event!(Page.locator(page, "body"), "wheel", %{deltaX: 100, deltaY: 200})
    assert JSHandle.evaluate!(events_handle, "e => e.length") == 1
    Utils.assert_truthy(JSHandle.evaluate!(events_handle, "e => e[0] instanceof WheelEvent"))

    assert JSHandle.evaluate!(
             events_handle,
             "e => ({ deltaX: e[0].deltaX, deltaY: e[0].deltaY })"
           ) ==
             %{"deltaX" => 100, "deltaY" => 200}
  end

  test "DE-014 should dispatch device orientation event", %{page: page, server: server} do
    # it.skip(isAndroid, ...)  -- not Android
    Page.goto!(page, server.prefix <> "/device-orientation.html")

    Locator.dispatch_event!(Page.locator(page, "html"), "deviceorientation", %{
      alpha: 10,
      beta: 20,
      gamma: 30
    })

    assert Page.evaluate!(page, "result") == "Oriented"
    assert Page.evaluate!(page, "alpha") == 10
    assert Page.evaluate!(page, "beta") == 20
    assert Page.evaluate!(page, "gamma") == 30
    Utils.assert_falsy(Page.evaluate!(page, "absolute"))
  end

  test "DE-015 should dispatch absolute device orientation event", %{page: page, server: server} do
    # it.skip(isAndroid, ...)  -- not Android
    Page.goto!(page, server.prefix <> "/device-orientation.html")

    Locator.dispatch_event!(Page.locator(page, "html"), "deviceorientationabsolute", %{
      alpha: 10,
      beta: 20,
      gamma: 30,
      absolute: true
    })

    assert Page.evaluate!(page, "result") == "Oriented"
    assert Page.evaluate!(page, "alpha") == 10
    assert Page.evaluate!(page, "beta") == 20
    assert Page.evaluate!(page, "gamma") == 30
    Utils.assert_truthy(Page.evaluate!(page, "absolute"))
  end

  test "DE-016 should dispatch device motion event", %{page: page, server: server} do
    # it.skip(isAndroid, ...)  -- not Android
    Page.goto!(page, server.prefix <> "/device-motion.html")

    Locator.dispatch_event!(Page.locator(page, "html"), "devicemotion", %{
      acceleration: %{x: 10, y: 20, z: 30},
      accelerationIncludingGravity: %{x: 15, y: 25, z: 35},
      rotationRate: %{alpha: 5, beta: 10, gamma: 15},
      interval: 16
    })

    assert Page.evaluate!(page, "result") == "Moved"
    assert Page.evaluate!(page, "acceleration.x") == 10
    assert Page.evaluate!(page, "acceleration.y") == 20
    assert Page.evaluate!(page, "acceleration.z") == 30
    assert Page.evaluate!(page, "accelerationIncludingGravity.x") == 15
    assert Page.evaluate!(page, "accelerationIncludingGravity.y") == 25
    assert Page.evaluate!(page, "accelerationIncludingGravity.z") == 35
    assert Page.evaluate!(page, "rotationRate.alpha") == 5
    assert Page.evaluate!(page, "rotationRate.beta") == 10
    assert Page.evaluate!(page, "rotationRate.gamma") == 15
    assert Page.evaluate!(page, "interval") == 16
  end

  # https://github.com/microsoft/playwright/issues/28690
  test "DE-017 should throw if argument is from different frame", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")

    data_transfer =
      page |> Page.frames() |> Enum.at(1) |> Frame.evaluate_handle!("() => new DataTransfer()")

    page
    |> Page.frame_locator("iframe")
    |> FrameLocator.locator("div")
    |> Locator.dispatch_event!("drop", %{dataTransfer: data_transfer})

    data_transfer = Page.evaluate_handle!(page, "() => new DataTransfer()")

    {:error, error} =
      page
      |> Page.frame_locator("iframe")
      |> FrameLocator.locator("div")
      |> Locator.dispatch_event("drop", %{dataTransfer: data_transfer})

    assert Exception.message(error) =~
             "JSHandles can be evaluated only in the context they were created!"
  end
end
