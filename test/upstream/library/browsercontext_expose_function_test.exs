defmodule PlaywrightEx.Library.BrowsercontextExposeFunctionTest do
  @upstream "tests/library/browsercontext-expose-function.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  # contextTest: a fresh context per test.
  setup %{context_factory: context_factory} do
    %{context: context_factory.([])}
  end

  test "expose binding should work", %{context: context} do
    test = self()

    BrowserContext.expose_binding!(context, "add", fn source, a, b ->
      send(test, {:binding_source, source})
      a + b
    end)

    page = BrowserContext.new_page!(context)
    result = Page.evaluate!(page, "add(5, 6)")
    assert_received {:binding_source, binding_source}
    assert binding_source.context == context
    assert binding_source.page == page
    assert binding_source.frame == Page.main_frame(page)
    assert result == 11
  end

  test "should work", %{context: context} do
    BrowserContext.expose_function!(context, "add", fn a, b -> a + b end)
    page = BrowserContext.new_page!(context)
    Page.expose_function!(page, "mul", fn a, b -> a * b end)
    BrowserContext.expose_function!(context, "sub", fn a, b -> a - b end)

    BrowserContext.expose_binding!(context, "addHandle", fn %{frame: frame}, a, b ->
      Frame.evaluate_handle!(frame, "([a, b]) => a + b", [a, b])
    end)

    result =
      Page.evaluate!(
        page,
        "(async () => ({ mul: await mul(9, 4), add: await add(9, 4), sub: await sub(9, 4), addHandle: await addHandle(5, 6) }))()"
      )

    assert result == %{"mul" => 36, "add" => 13, "sub" => 5, "addHandle" => 11}
  end

  test "should dispose", %{context: context} do
    binding = BrowserContext.expose_function!(context, "compute", fn a, b -> a * b end)
    page = BrowserContext.new_page!(context)
    result = Page.evaluate!(page, "async () => await window['compute'](9, 4)")
    assert result == 36
    Disposable.dispose!(binding)

    {:error, e} = Page.evaluate(page, "async () => await window['compute'](9, 4)")
    assert e.message =~ "is not a function"
  end

  test "should throw for duplicate registrations", %{context: context} do
    BrowserContext.expose_function!(context, "foo", fn -> nil end)
    BrowserContext.expose_function!(context, "bar", fn -> nil end)
    {:error, error} = BrowserContext.expose_function(context, "foo", fn -> nil end)
    assert error.message =~ ~s(Function "foo" has been already registered)
    page = BrowserContext.new_page!(context)
    {:error, error} = Page.expose_function(page, "foo", fn -> nil end)
    assert error.message =~ ~s(Function "foo" has been already registered in the browser context)
    Page.expose_function!(page, "baz", fn -> nil end)
    {:error, error} = BrowserContext.expose_function(context, "baz", fn -> nil end)
    assert error.message =~ ~s(Function "baz" has been already registered in one of the pages)
  end

  test "should be callable from-inside addInitScript", %{context: context} do
    test = self()
    BrowserContext.expose_function!(context, "woof", fn arg -> send(test, {:arg, arg}) end)
    BrowserContext.add_init_script!(context, ~s|window["woof"]("context")|)
    page = BrowserContext.new_page!(context)
    Page.evaluate!(page, "undefined")
    # await expect.poll(() => args).toEqual(['context']);
    assert_receive {:arg, "context"}, 5000
    Page.add_init_script!(page, ~s|window["woof"]("page")|)
    Page.reload!(page)
    assert_receive {:arg, "context"}, 5000
    assert_receive {:arg, "page"}, 5000
  end

  test "should work with CSP", %{context: context, server: server} do
    page = BrowserContext.new_page!(context)
    TestServer.set_csp(server, "/empty.html", ~s(default-src "self"))
    Page.goto!(page, server.empty_page)
    test = self()

    BrowserContext.expose_binding!(context, "hi", fn ->
      send(test, :called)
      true
    end)

    Page.evaluate!(page, "() => window.hi()")
    assert_received :called
  end

  @tag skip:
         if(@browser_name == "chromium",
           do: "upstream fixme: Chromium drops CDP events from the old document after the frame host swap"
         )
  test "should call binding from pagehide handler when navigating away", %{
    context: context,
    server: server
  } do
    # it.fixme(browserName === 'chromium', 'Chromium drops CDP events from the old document after the frame host swap');
    page = BrowserContext.new_page!(context)
    test = self()

    BrowserContext.expose_binding!(context, "reportFromPage", fn _source, message ->
      send(test, {:call, message})
      nil
    end)

    html = fn body ->
      "<!doctype html>#{body}<script>addEventListener('pagehide', () => window.reportFromPage('pagehide of ' + location.pathname));</script>"
    end

    for {path, body} <- [{"/a.html", ~s(<a id="next" href="/b.html">next</a>)}, {"/b.html", "<p>b</p>"}] do
      TestServer.set_route(server, path, fn conn ->
        conn |> Plug.Conn.put_resp_header("content-type", "text/html") |> Plug.Conn.send_resp(200, html.(body))
      end)
    end

    Page.goto!(page, server.prefix <> "/a.html")
    Page.click!(page, "#next")
    Page.wait_for_url!(page, "**/b.html")
    # await expect.poll(() => calls).toContain('pagehide of /a.html');
    assert_receive {:call, "pagehide of /a.html"}, 5000
  end
end
