defmodule PlaywrightEx.Library.LocatorDispatcheventTouchTest do
  @upstream "tests/library/locator-dispatchevent-touch.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  # it.use({ hasTouch: true })
  setup %{context_factory: context_factory} do
    context = context_factory.(has_touch: true)
    %{page: BrowserContext.new_page!(context)}
  end

  test "should support touch points in touch event arguments", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
          <div data-testid='outer' style="position: absolute; width: 120px; height: 120px; background-color: red;">
            <div data-testid='inner' style="position: absolute; width: 100px; height: 100px; top: 10px; left: 10px; background-color: green; z-index: 3;">inner</div>
          </div>
    """)

    outer = Page.get_by_test_id(page, "outer")

    Locator.evaluate!(outer, """
    (el) => {
      const events = [];
      window.events = events;
      el.addEventListener('touchstart', (e) => events.push('touchstart: ' + [...e.touches].map(t => `${t.constructor.name}(id: ${t.identifier}, clientX: ${t.clientX}, clientY: ${t.clientY})`)));
      el.addEventListener('touchmove', (e) => events.push('touchmove: ' + [...e.touches].map(t => `${t.constructor.name}(id: ${t.identifier}, clientX: ${t.clientX}, clientY: ${t.clientY})`)));
      el.addEventListener('touchend', (e) => events.push('touchend: ' + [...e.touches].map(t => `${t.constructor.name}(id: ${t.identifier}, clientX: ${t.clientX}, clientY: ${t.clientY})`)));
    }
    """)

    touches = [%{identifier: 0, clientX: 61, clientY: 60}, %{identifier: 1, clientX: 59, clientY: 60}]
    inner = Page.get_by_test_id(page, "inner")

    Locator.dispatch_event!(inner, "touchstart", %{
      touches: touches,
      changedTouches: touches,
      targetTouches: touches
    })

    Locator.dispatch_event!(inner, "touchmove", %{
      touches: touches,
      changedTouches: touches,
      targetTouches: touches
    })

    Locator.dispatch_event!(inner, "touchend", %{
      touches: [],
      changedTouches: touches,
      targetTouches: []
    })

    assert Page.evaluate!(page, "() => window.events") == [
             "touchstart: Touch(id: 0, clientX: 61, clientY: 60),Touch(id: 1, clientX: 59, clientY: 60)",
             "touchmove: Touch(id: 0, clientX: 61, clientY: 60),Touch(id: 1, clientX: 59, clientY: 60)",
             "touchend: "
           ]
  end
end
