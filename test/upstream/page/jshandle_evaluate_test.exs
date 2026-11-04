defmodule PlaywrightEx.Page.JshandleEvaluateTest do
  @upstream "tests/page/jshandle-evaluate.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "should work with function @smoke", %{page: page} do
    window_handle =
      Page.evaluate_handle!(page, """
      () => {
        window['foo'] = [1, 2];
        return window;
      }
      """)

    assert JSHandle.evaluate!(window_handle, "w => w['foo']") == [1, 2]
  end

  test "should work with expression", %{page: page} do
    window_handle =
      Page.evaluate_handle!(page, """
      () => {
        window['foo'] = [1, 2];
        return window;
      }
      """)

    assert JSHandle.evaluate!(window_handle, "window.foo") == [1, 2]
  end
end
