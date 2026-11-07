defmodule PlaywrightEx.Page.JshandlePropertiesTest do
  @upstream "tests/page/jshandle-properties.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "JH-010 should work @smoke", %{page: page} do
    a_handle = Page.evaluate_handle!(page, "() => ({ one: 1, two: 2, three: 3 })")
    two_handle = JSHandle.get_property!(a_handle, "two")
    assert JSHandle.json_value!(two_handle) == 2
  end

  test "JH-011 should work with undefined, null, and empty", %{page: page} do
    a_handle = Page.evaluate_handle!(page, "() => ({ undefined: undefined, null: null })")
    undefined_handle = JSHandle.get_property!(a_handle, "undefined")
    assert JSHandle.json_value!(undefined_handle) == nil
    null_handle = JSHandle.get_property!(a_handle, "null")
    assert JSHandle.json_value!(null_handle) == :null
    emptyhandle = JSHandle.get_property!(a_handle, "empty")
    assert JSHandle.json_value!(emptyhandle) == nil
  end

  test "JH-012 should work with unserializable values", %{page: page} do
    a_handle =
      Page.evaluate_handle!(page, "() => ({ infinity: Infinity, nInfinity: -Infinity, nan: NaN, nzero: -0 })")

    infinity_handle = JSHandle.get_property!(a_handle, "infinity")
    assert JSHandle.json_value!(infinity_handle) == :infinity
    n_infinity_handle = JSHandle.get_property!(a_handle, "nInfinity")
    assert JSHandle.json_value!(n_infinity_handle) == :neg_infinity
    nan_handle = JSHandle.get_property!(a_handle, "nan")
    assert JSHandle.json_value!(nan_handle) == :nan
    nzero_handle = JSHandle.get_property!(a_handle, "nzero")
    assert JSHandle.json_value!(nzero_handle) === -0.0
  end

  test "JH-013 getProperties should work", %{page: page} do
    a_handle = Page.evaluate_handle!(page, "() => ({ foo: 'bar' })")
    properties = JSHandle.get_properties!(a_handle)
    foo = properties["foo"]
    assert foo
    assert JSHandle.json_value!(foo) == "bar"
  end

  test "JH-014 getProperties should return empty map for non-objects", %{page: page} do
    a_handle = Page.evaluate_handle!(page, "() => 123")
    properties = JSHandle.get_properties!(a_handle)
    assert map_size(properties) == 0
  end

  test "JH-015 getProperties should return properties inhertied from super class", %{page: page} do
    a_handle =
      Page.evaluate_handle!(page, """
      () => {
        class A {
          constructor() {
            this.a = '1';
          }
        }
        class B extends A {
          constructor() {
            super();
            this.b = '2';
          }
        }
        return new B();
      }
      """)

    properties = JSHandle.get_properties!(a_handle)
    assert JSHandle.json_value!(properties["a"]) == "1"
    assert JSHandle.json_value!(properties["b"]) == "2"
  end

  test "JH-016 getProperties should return own enumerable properties only", %{page: page} do
    a_handle =
      Page.evaluate_handle!(page, """
      () => {
        class A {
          constructor() {
            this.own = 1;
            Object.defineProperty(this, 'ownHidden', { value: 2, enumerable: false });
          }
        }
        A.prototype.inherited = 3;
        return new A();
      }
      """)

    assert Map.keys(JSHandle.get_properties!(a_handle)) == ["own"]

    Page.set_content!(page, "<div id=d><span>a</span><span>b</span></div>")
    collection = Page.evaluate_handle!(page, "() => document.querySelector('#d').children")
    assert Map.keys(JSHandle.get_properties!(collection)) == ["0", "1"]
  end

  test "JH-017 getProperties should work with elements", %{page: page} do
    Page.set_content!(page, "<div>Hello</div>")
    handle = Page.evaluate_handle!(page, "() => ({ body: document.body })")
    properties = JSHandle.get_properties!(handle)
    body = properties["body"]
    assert body
    assert ElementHandle.text_content!(body) == "Hello"
  end
end
