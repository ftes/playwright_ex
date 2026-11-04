defmodule PlaywrightEx.Page.JshandleJsonValueTest do
  @upstream "tests/page/jshandle-json-value.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "should work @smoke", %{page: page} do
    a_handle = Page.evaluate_handle!(page, "() => ({ foo: 'bar' })")
    json = JSHandle.json_value!(a_handle)
    assert json == %{"foo" => "bar"}
  end

  test "should work with dates", %{page: page} do
    date_handle = Page.evaluate_handle!(page, "() => new Date('2017-09-26T00:00:00.000Z')")
    date = JSHandle.json_value!(date_handle)
    assert DateTime.to_iso8601(date) == "2017-09-26T00:00:00.000Z"
  end

  test "should handle circular objects", %{page: page} do
    handle = Page.evaluate_handle!(page, "const a = {}; a.b = a; a")
    # Elixir terms are acyclic: the reference to the enclosing object is `:circular`.
    assert JSHandle.json_value!(handle) == %{"b" => :circular}
  end
end
