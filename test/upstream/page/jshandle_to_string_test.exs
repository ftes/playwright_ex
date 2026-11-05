defmodule PlaywrightEx.Page.JshandleToStringTest do
  @upstream "tests/page/jshandle-to-string.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  @moduletag :page

  # `handle.toString()` is `to_string(handle)` (String.Chars).

  test "should work for primitives", %{page: page} do
    number_handle = Page.evaluate_handle!(page, "() => 2")
    assert to_string(number_handle) == "2"
    string_handle = Page.evaluate_handle!(page, "() => 'a'")
    assert to_string(string_handle) == "a"
  end

  test "should work for complicated objects", %{page: page, browser_name: browser_name} do
    a_handle = Page.evaluate_handle!(page, "() => window")

    if browser_name != "firefox",
      do: assert(to_string(a_handle) == "Window"),
      else: assert(to_string(a_handle) == "JSHandle@object")
  end

  test "should beautifully render sparse arrays", %{page: page, browser_name: browser_name} do
    msg =
      Page.expect_event!(page, :console, fn ->
        Page.evaluate_handle!(page, """
        () => {
          const a = [];
          a[1] = 1;
          a[10] = 2;
          a[100] = 3;
          console.log(a);
        }
        """)
      end)

    if browser_name == "firefox",
      do: assert(ConsoleMessage.text(msg) == "Array"),
      else: assert(ConsoleMessage.text(msg) == "[empty, 1, empty x 8, 2, empty x 89, 3]")
  end

  test "should work for promises", %{page: page} do
    # wrap the promise in an object, otherwise we will await.
    wrapper_handle = Page.evaluate_handle!(page, "() => ({ b: Promise.resolve(123) })")
    b_handle = JSHandle.get_property!(wrapper_handle, "b")
    assert to_string(b_handle) == "Promise"
  end

  test "should work with different subtypes @smoke", %{page: page, browser_name: browser_name} do
    # Page functions are JS source without `isFunction` (PLAN): the driver calls a function
    # expression, so return the function from one.
    assert to_string(Page.evaluate_handle!(page, "() => (function(){})")) =~ "function"
    assert to_string(Page.evaluate_handle!(page, "12")) == "12"
    assert to_string(Page.evaluate_handle!(page, "true")) == "true"
    assert to_string(Page.evaluate_handle!(page, "undefined")) == "undefined"
    assert to_string(Page.evaluate_handle!(page, ~s("foo"))) == "foo"
    assert to_string(Page.evaluate_handle!(page, "Symbol()")) == "Symbol()"
    assert to_string(Page.evaluate_handle!(page, "new Map()")) =~ "Map"
    assert to_string(Page.evaluate_handle!(page, "new Set()")) =~ "Set"
    assert to_string(Page.evaluate_handle!(page, "[]")) =~ "Array"
    assert to_string(Page.evaluate_handle!(page, "null")) == "null"
    body_handle = Page.evaluate_handle!(page, "document.body")
    Utils.poll(fn -> to_string(body_handle) end, &assert(&1 == "JSHandle@<body></body>"))
    assert to_string(Page.evaluate_handle!(page, "new WeakMap()")) == "WeakMap"
    assert to_string(Page.evaluate_handle!(page, "new WeakSet()")) == "WeakSet"
    assert to_string(Page.evaluate_handle!(page, "new Error()")) =~ "Error"

    assert to_string(Page.evaluate_handle!(page, "new Proxy({}, {})")) ==
             if(browser_name == "chromium", do: "Proxy(Object)", else: "Proxy")
  end

  @tag skip: if(@browser_name == "firefox", do: "upstream skip: firefox (non-BiDi)")
  test "should work with previewable subtypes", %{page: page} do
    assert to_string(Page.evaluate_handle!(page, "/foo/")) == "/foo/"
    assert to_string(Page.evaluate_handle!(page, "new Date(0)")) =~ "GMT"
    assert to_string(Page.evaluate_handle!(page, "new Int32Array()")) =~ "Int32Array"
  end
end
