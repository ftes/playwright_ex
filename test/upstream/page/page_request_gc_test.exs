defmodule PlaywrightEx.Page.PageRequestGcTest do
  @upstream "tests/page/page-request-gc.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")

  test "RO-149 should work", %{page: page} do
    Page.evaluate!(page, """
    () => {
      globalThis.objectToDestroy = { hello: 'world' };
      globalThis.weakRef = new WeakRef(globalThis.objectToDestroy);
    }
    """)

    Page.request_gc!(page)
    assert Page.evaluate!(page, "() => globalThis.weakRef.deref()") == %{"hello" => "world"}

    Page.request_gc!(page)
    assert Page.evaluate!(page, "() => globalThis.weakRef.deref()") == %{"hello" => "world"}

    Page.evaluate!(page, "() => globalThis.objectToDestroy = null")
    Page.request_gc!(page)
    assert Page.evaluate!(page, "() => globalThis.weakRef.deref()") == nil
  end

  @tag skip:
         (case @browser_name do
            "firefox" ->
              "upstream fixme: Firefox hit-target interceptor does not release its element reference on detach"

            "chromium" ->
              "upstream fixme: Chromium retains a native reference to the last hit-tested element (#41575)"

            _ ->
              false
          end)
  test "RO-150 should collect element retained by locator hit-target interceptor after detach", %{page: page} do
    Page.set_content!(page, ~s|<button id="btn">click me</button>|)
    Locator.click!(Page.locator(page, "#btn"))

    Page.evaluate!(page, """
    () => {
      globalThis.weakRef = new WeakRef(document.getElementById('btn'));
      document.getElementById('btn').remove();
    }
    """)

    Page.request_gc!(page)
    assert Page.evaluate!(page, "() => globalThis.weakRef.deref()") == nil
  end
end
