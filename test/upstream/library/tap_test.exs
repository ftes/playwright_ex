defmodule PlaywrightEx.Library.TapTest do
  @upstream "tests/library/tap.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Touchscreen

  # it.use({ hasTouch: true })
  setup %{context_factory: context_factory} do
    context = context_factory.(has_touch: true)
    %{page: BrowserContext.new_page!(context)}
  end

  test "should send all of the correct events @smoke", %{page: page} do
    Page.set_content!(page, """
      <div id="a" style="background: lightblue; width: 50px; height: 50px">a</div>
      <div id="b" style="background: pink; width: 50px; height: 50px">b</div>
    """)

    Page.tap!(page, "#a")
    events_handle = track_events(Page.query_selector!(page, "#b"))
    Page.tap!(page, "#b")
    # webkit doesn't send pointerenter or pointerleave or mouseout
    assert JSHandle.json_value!(events_handle) == [
             "pointerover",
             "pointerenter",
             "pointerdown",
             "touchstart",
             "pointerup",
             "pointerout",
             "pointerleave",
             "touchend",
             "mouseover",
             "mouseenter",
             "mousemove",
             "mousedown",
             "mouseup",
             "click"
           ]
  end

  test "trial run should not tap", %{page: page} do
    Page.set_content!(page, """
        <div id="a" style="background: lightblue; width: 50px; height: 50px">a</div>
        <div id="b" style="background: pink; width: 50px; height: 50px">b</div>
    """)

    Page.tap!(page, "#a")
    events_handle = track_events(Page.query_selector!(page, "#b"))
    Page.tap!(page, "#b", trial: true)
    expected = ["pointerover", "pointerenter", "pointerout", "pointerleave"]
    assert JSHandle.json_value!(events_handle) == expected
  end

  test "should not send mouse events touchstart is canceled", %{page: page} do
    Page.set_content!(page, ~s(<div style="width: 50px; height: 50px; background: red">))

    Page.evaluate!(page, """
    () => {
      // touchstart is not cancelable unless passive is false
      document.addEventListener('touchstart', t => t.preventDefault(), { passive: false });
    }
    """)

    events_handle = track_events(Page.query_selector!(page, "div"))
    Page.tap!(page, "div")

    assert JSHandle.json_value!(events_handle) == [
             "pointerover",
             "pointerenter",
             "pointerdown",
             "touchstart",
             "pointerup",
             "pointerout",
             "pointerleave",
             "touchend"
           ]
  end

  test "should not send mouse events when touchend is canceled", %{page: page} do
    Page.set_content!(page, ~s(<div style="width: 50px; height: 50px; background: red">))

    Page.evaluate!(page, """
    () => {
      document.addEventListener('touchend', t => t.preventDefault());
    }
    """)

    events_handle = track_events(Page.query_selector!(page, "div"))
    Page.tap!(page, "div")

    assert JSHandle.json_value!(events_handle) == [
             "pointerover",
             "pointerenter",
             "pointerdown",
             "touchstart",
             "pointerup",
             "pointerout",
             "pointerleave",
             "touchend"
           ]
  end

  test "should not wait for a navigation caused by a tap", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a href="/intercept-this.html">link</a>;))
    me = self()

    TestServer.set_route(server, "/intercept-this.html", fn conn ->
      send(me, {:intercepted, conn})
      # Never responds, as upstream's `resolve` route.
      Process.sleep(:infinity)
    end)

    Page.tap!(page, "a")
    assert_receive {:intercepted, _conn}, 5000
  end

  # Deviation: `page.evaluate(() => new Promise(...))` started without `await` is an evaluate of
  # `{ p: new Promise(...) }` (the listener is installed before the next call), awaited later.
  test "should work with modifiers", %{page: page} do
    Page.set_content!(page, "hello world")

    alt_key_promise =
      Page.evaluate_handle!(page, """
      () => ({ p: new Promise(resolve => {
        document.addEventListener('touchstart', event => {
          resolve(event.altKey);
        }, { passive: false });
      }) })
      """)

    # make sure the evals hit the page
    Page.evaluate!(page, "() => void 0")
    Page.tap!(page, "body", modifiers: ["Alt"])
    assert JSHandle.evaluate!(alt_key_promise, "o => o.p") == true
  end

  test "should send well formed touch points", %{page: page} do
    promises =
      Page.evaluate_handle!(page, """
      () => [
        new Promise(resolve => {
          document.addEventListener('touchstart', event => {
            resolve([...event.touches].map(t => ({
              identifier: t.identifier,
              clientX: t.clientX,
              clientY: t.clientY,
              pageX: t.pageX,
              pageY: t.pageY,
              radiusX: 'radiusX' in t ? t.radiusX : t['webkitRadiusX'],
              radiusY: 'radiusY' in t ? t.radiusY : t['webkitRadiusY'],
              rotationAngle: 'rotationAngle' in t ? t.rotationAngle : t['webkitRotationAngle'],
              force: 'force' in t ? t.force : t['webkitForce'],
            })));
          }, false);
        }),
        new Promise(resolve => {
          document.addEventListener('touchend', event => {
            resolve([...event.touches].map(t => ({
              identifier: t.identifier,
              clientX: t.clientX,
              clientY: t.clientY,
              pageX: t.pageX,
              pageY: t.pageY,
              radiusX: 'radiusX' in t ? t.radiusX : t['webkitRadiusX'],
              radiusY: 'radiusY' in t ? t.radiusY : t['webkitRadiusY'],
              rotationAngle: 'rotationAngle' in t ? t.rotationAngle : t['webkitRotationAngle'],
              force: 'force' in t ? t.force : t['webkitForce'],
            })));
          }, false);
        }),
      ]
      """)

    # make sure the evals hit the page
    Page.evaluate!(page, "() => void 0")
    Touchscreen.tap!(Page.touchscreen(page), 40, 60)
    [touchstart, touchend] = JSHandle.evaluate!(promises, "promises => Promise.all(promises)")

    assert touchstart == [
             %{
               "clientX" => 40,
               "clientY" => 60,
               "force" => 1,
               "identifier" => 0,
               "pageX" => 40,
               "pageY" => 60,
               "radiusX" => 1,
               "radiusY" => 1,
               "rotationAngle" => 0
             }
           ]

    assert touchend == []
  end

  test "should wait until an element is visible to tap it", %{page: page} do
    div =
      page
      |> Page.evaluate_handle!("""
      () => {
        const button = document.createElement('button');
        button.textContent = 'not clicked';
        document.body.appendChild(button);
        button.style.display = 'none';
        return button;
      }
      """)
      |> JSHandle.as_element()

    tap_promise = Task.async(fn -> ElementHandle.tap!(div) end)
    JSHandle.evaluate!(div, "div => div.onclick = () => div.textContent = 'clicked'")
    JSHandle.evaluate!(div, "div => div.style.display = 'block'")
    Task.await(tap_promise, :infinity)
    assert ElementHandle.text_content!(div) == "clicked"
  end

  defp track_events(target) do
    JSHandle.evaluate_handle!(target, """
    target => {
      const events = [];
      for (const event of [
        'mousedown', 'mouseenter', 'mouseleave', 'mousemove', 'mouseout', 'mouseover', 'mouseup', 'click',
        'pointercancel', 'pointerdown', 'pointerenter', 'pointerleave', 'pointermove', 'pointerout', 'pointerover', 'pointerup',
        'touchstart', 'touchend', 'touchmove', 'touchcancel',
      ])
        target.addEventListener(event, () => events.push(event), false);
      return events;
    }
    """)
  end

  describe "locators" do
    test "should send all of the correct events", %{page: page} do
      Page.set_content!(page, """
        <div id="a" style="background: lightblue; width: 50px; height: 50px">a</div>
        <div id="b" style="background: pink; width: 50px; height: 50px">b</div>
      """)

      Locator.tap!(Page.locator(page, "#a"))
      Locator.tap!(Page.locator(page, "#b"))
    end
  end
end
