defmodule PlaywrightEx.Page.JshandleAsElementTest do
  @upstream "tests/page/jshandle-as-element.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  @moduletag :page

  test "should work @smoke", %{page: page} do
    a_handle = Page.evaluate_handle!(page, "() => document.body")
    element = JSHandle.as_element(a_handle)
    assert element
  end

  test "should return null for non-elements", %{page: page} do
    a_handle = Page.evaluate_handle!(page, "() => 2")
    element = JSHandle.as_element(a_handle)
    refute element
  end

  test "should return ElementHandle for TextNodes", %{page: page} do
    Page.set_content!(page, "<div>ee!</div>")
    a_handle = Page.evaluate_handle!(page, "() => document.querySelector('div').firstChild")
    element = JSHandle.as_element(a_handle)
    assert element
    Utils.assert_truthy(Page.evaluate!(page, "e => e.nodeType === Node.TEXT_NODE", element))
  end

  test "should work with nullified Node", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    Page.evaluate!(page, "delete Node")
    handle = Page.evaluate_handle!(page, "() => document.querySelector('section')")
    element = JSHandle.as_element(handle)
    assert element != nil
  end
end
