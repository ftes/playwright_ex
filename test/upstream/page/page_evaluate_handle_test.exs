defmodule PlaywrightEx.Page.PageEvaluateHandleTest do
  @upstream "tests/page/page-evaluate-handle.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  test "should work", %{page: page} do
    window_handle = Page.evaluate_handle!(page, "() => window")
    assert window_handle
  end

  test "should accept object handle as an argument", %{page: page} do
    navigator_handle = Page.evaluate_handle!(page, "() => navigator")
    text = Page.evaluate!(page, "e => e.userAgent", navigator_handle)
    assert text =~ "Mozilla"
  end

  test "should accept object handle to primitive types", %{page: page} do
    a_handle = Page.evaluate_handle!(page, "() => 5")
    is_five = Page.evaluate!(page, "e => Object.is(e, 5)", a_handle)
    assert is_five
  end

  test "should accept nested handle", %{page: page} do
    foo = Page.evaluate_handle!(page, "() => ({ x: 1, y: 'foo' })")
    result = Page.evaluate!(page, "({ foo }) => { return foo; }", %{foo: foo})
    assert result == %{"x" => 1, "y" => "foo"}
  end

  test "should accept nested window handle", %{page: page} do
    foo = Page.evaluate_handle!(page, "() => window")
    result = Page.evaluate!(page, "({ foo }) => { return foo === window; }", %{foo: foo})
    assert result == true
  end

  test "should accept multiple nested handles", %{page: page} do
    foo = Page.evaluate_handle!(page, "() => ({ x: 1, y: 'foo' })")
    bar = Page.evaluate_handle!(page, "() => 5")
    baz = Page.evaluate_handle!(page, "() => (['baz'])")

    result =
      Page.evaluate!(page, "x => { return JSON.stringify(x); }", %{a1: %{foo: foo}, a2: %{bar: bar, arr: [%{baz: baz}]}})

    assert JSON.decode!(result) == %{
             "a1" => %{"foo" => %{"x" => 1, "y" => "foo"}},
             "a2" => %{"bar" => 5, "arr" => [%{"baz" => ["baz"]}]}
           }
  end

  test "should accept same handle multiple times", %{page: page} do
    foo = Page.evaluate_handle!(page, "() => 1")

    assert Page.evaluate!(page, "x => x", %{foo: foo, bar: [foo], baz: %{foo: foo}}) ==
             %{"foo" => 1, "bar" => [1], "baz" => %{"foo" => 1}}
  end

  test "should accept same nested object multiple times", %{page: page} do
    foo = %{x: 1}

    assert Page.evaluate!(page, "x => x", %{foo: foo, bar: [foo], baz: %{foo: foo}}) ==
             %{"foo" => %{"x" => 1}, "bar" => [%{"x" => 1}], "baz" => %{"foo" => %{"x" => 1}}}
  end

  test "should accept object handle to unserializable value", %{page: page} do
    a_handle = Page.evaluate_handle!(page, "() => Infinity")
    assert Page.evaluate!(page, "e => Object.is(e, Infinity)", a_handle) == true
  end

  test "should pass configurable args", %{page: page} do
    result =
      Page.evaluate!(
        page,
        """
        arg => {
          if (arg.foo !== 42)
            throw new Error('Not a 42');
          arg.foo = 17;
          if (arg.foo !== 17)
            throw new Error('Not 17');
          delete arg.foo;
          if (arg.foo === 17)
            throw new Error('Still 17');
          return arg;
        }
        """,
        %{foo: 42}
      )

    assert result == %{}
  end

  test "should work with primitives", %{page: page} do
    a_handle =
      Page.evaluate_handle!(page, """
      () => {
        window['FOO'] = 123;
        return window;
      }
      """)

    assert Page.evaluate!(page, "e => e['FOO']", a_handle) == 123
  end
end
