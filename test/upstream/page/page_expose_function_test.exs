defmodule PlaywrightEx.Page.PageExposeFunctionTest do
  @upstream "tests/page/page-expose-function.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer

  @moduletag :page

  test "EF-001 exposeBinding should work @smoke", %{page: page} do
    test = self()

    Page.expose_binding!(page, "add", fn source, a, b ->
      send(test, {:binding_source, source})
      a + b
    end)

    result = Page.evaluate!(page, "async () => window['add'](5, 6)")
    assert_received {:binding_source, binding_source}
    assert binding_source.context == Page.context(page)
    assert binding_source.page == page
    assert binding_source.frame == Page.main_frame(page)
    assert result == 11
  end

  test "EF-002 should work", %{page: page} do
    Page.expose_function!(page, "compute", fn a, b -> a * b end)
    result = Page.evaluate!(page, "async () => await window['compute'](9, 4)")
    assert result == 36
  end

  test "EF-003 should dispose", %{page: page} do
    binding = Page.expose_function!(page, "compute", fn a, b -> a * b end)
    result = Page.evaluate!(page, "async () => await window['compute'](9, 4)")
    assert result == 36
    Disposable.dispose!(binding)

    {:error, e} = Page.evaluate(page, "async () => await window['compute'](9, 4)")
    assert e.message =~ "is not a function"
  end

  test "EF-004 should work with handles and complex objects", %{page: page} do
    foo_handle =
      Page.evaluate_handle!(page, """
      () => {
        window['fooValue'] = { bar: 2 };
        return window['fooValue'];
      }
      """)

    Page.expose_function!(page, "handle", fn -> [%{foo: foo_handle}] end)

    equals =
      Page.evaluate!(page, """
      async () => {
        const value = await window['handle']();
        const [{ foo }] = value;
        return foo === window['fooValue'];
      }
      """)

    assert equals == true
  end

  test "EF-005 should throw exception in page context", %{page: page} do
    Page.expose_function!(page, "woof", fn -> raise "WOOF WOOF" end)

    %{"message" => message, "stack" => stack} =
      Page.evaluate!(page, """
      async () => {
        try {
          await window['woof']();
        } catch (e) {
          return { message: e.message, stack: e.stack };
        }
      }
      """)

    assert message == "WOOF WOOF"
    # Deviation: Elixir exceptions carry no JS stack, so it does not contain __filename.
    assert is_binary(stack)
  end

  test "EF-006 should support throwing \"null\"", %{page: page} do
    # `throw null` is an Elixir throw.
    Page.expose_function!(page, "woof", fn -> throw(:null) end)

    thrown =
      Page.evaluate!(page, """
      async () => {
        try {
          await window['woof']();
        } catch (e) {
          return e;
        }
      }
      """)

    assert thrown == :null
  end

  test "EF-007 should be callable from-inside addInitScript", %{page: page} do
    test = self()
    Page.expose_function!(page, "woof", fn -> send(test, :called) end)
    Page.add_init_script!(page, "window['woof']()")
    Page.reload!(page)
    # await expect.poll(() => called).toBe(true);
    assert_receive :called, 5000
  end

  test "EF-008 should survive navigation", %{page: page, server: server} do
    Page.expose_function!(page, "compute", fn a, b -> a * b end)

    Page.goto!(page, server.empty_page)
    result = Page.evaluate!(page, "async () => await window['compute'](9, 4)")
    assert result == 36
  end

  test "EF-009 should await returned promise", %{page: page} do
    # Promise.resolve(a * b): a returned promise is awaited.
    Page.expose_function!(page, "compute", fn a, b -> Runtime.Promise.resolved(a * b) end)

    result = Page.evaluate!(page, "async () => await window['compute'](3, 5)")
    assert result == 15
  end

  test "EF-010 should work on frames", %{page: page, server: server} do
    Page.expose_function!(page, "compute", fn a, b -> Runtime.Promise.resolved(a * b) end)

    Page.goto!(page, server.prefix <> "/frames/nested-frames.html")
    frame = Enum.at(Page.frames(page), 1)
    result = Frame.evaluate!(frame, "async () => await window['compute'](3, 5)")
    assert result == 15
  end

  test "EF-011 should work on frames before navigation", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/nested-frames.html")
    Page.expose_function!(page, "compute", fn a, b -> Runtime.Promise.resolved(a * b) end)

    frame = Enum.at(Page.frames(page), 1)
    result = Frame.evaluate!(frame, "async () => await window['compute'](3, 5)")
    assert result == 15
  end

  test "EF-012 should work after cross origin navigation", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.expose_function!(page, "compute", fn a, b -> a * b end)

    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    result = Page.evaluate!(page, "async () => await window['compute'](9, 4)")
    assert result == 36
  end

  test "EF-013 should work with complex objects", %{page: page} do
    Page.expose_function!(page, "complexObject", fn a, b -> %{x: a["x"] + b["x"]} end)
    result = Page.evaluate!(page, "async () => window['complexObject']({ x: 5 }, { x: 2 })")
    assert result["x"] == 7
  end

  test "EF-014 should throw for duplicate registrations", %{page: page} do
    Page.expose_function!(page, "foo", fn -> nil end)
    {:error, error} = Page.expose_function(page, "foo", fn -> nil end)
    assert error.message =~ ~s(page.exposeFunction: Function "foo" has been already registered)
  end

  test "EF-015 should work with setContent", %{page: page} do
    Page.expose_function!(page, "compute", fn a, b -> Runtime.Promise.resolved(a * b) end)
    Page.set_content!(page, "<script>window.result = compute(3, 2)</script>")
    assert Page.evaluate!(page, "window.result") == 6
  end

  test "EF-016 should alias Window, Document and Node", %{page: page} do
    test = self()
    # object = obj (the assignment's value is returned to the page)
    Page.expose_binding!(page, "log", fn _source, obj ->
      send(test, {:object, obj})
      obj
    end)

    Page.evaluate!(page, "window.log([window, document, document.body])")
    assert_received {:object, object}
    assert object == ["ref: <Window>", "ref: <Document>", "ref: <Node>"]
  end

  test "EF-017 should serialize cycles", %{page: page} do
    test = self()
    # object = obj (the assignment's value is returned to the page)
    Page.expose_binding!(page, "log", fn _source, obj ->
      send(test, {:object, obj})
      obj
    end)

    Page.evaluate!(page, "const a = {}; a.b = a; window.log(a)")
    assert_received {:object, object}
    # Deviation: Elixir terms are acyclic, the cycle parses to :circular.
    assert object == %{"b" => :circular}
  end

  test "EF-018 should work with overridden console object", %{page: page} do
    Page.evaluate!(page, "() => window.console = null")
    assert Page.evaluate!(page, "() => window.console === null")
    Page.expose_function!(page, "add", fn a, b -> a + b end)
    assert Page.evaluate!(page, "add(5, 6)") == 11
  end

  test "EF-019 should work with busted Array.prototype.map/push", %{page: page, server: server} do
    TestServer.set_route(server, "/test", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
      <script>
        Array.prototype.map = null;
        Array.prototype.push = null;
      </script>
      """)
    end)

    Page.goto!(page, server.prefix <> "/test")
    Page.expose_function!(page, "add", fn a, b -> a + b end)
    assert Page.evaluate!(page, "add(5, 6)") == 11
  end

  test "EF-020 should fail with busted Array.prototype.toJSON", %{page: page} do
    Page.evaluate_handle!(page, ~s|() => Array.prototype.toJSON = () => '"[]"'|)

    Page.expose_function!(page, "add", fn a, b -> a + b end)
    {:error, e} = Page.evaluate(page, "add(5, 6)")

    assert e.message =~
             "serializedArgs is not an array. This can happen when Array.prototype.toJSON is defined incorrectly"

    assert Page.evaluate!(page, "() => ([]).toJSON()") == ~s("[]")
  end

  test "EF-021 exposeBinding should work in parallel", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/37712' }
    [{:ok, _}, {:ok, _}] =
      [
        Task.async(fn -> Page.expose_binding(page, "foo", fn -> 42 end) end),
        Task.async(fn -> Page.expose_binding(page, "bar", fn -> 42 end) end)
      ]
      |> Task.await_many(:infinity)

    Page.evaluate!(page, """
    () => {
      window.foo();
      window.bar();
    }
    """)
  end
end
