defmodule PlaywrightEx.Library.BrowsercontextCspTest do
  @upstream "tests/library/browsercontext-csp.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils

  import PlaywrightEx.Utils, only: [attach_frame: 3]

  test "CS-001 should bypass CSP meta tag @smoke", %{browser: browser, server: server} do
    # Make sure CSP prohibits addScriptTag.
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/csp.html")
    assert Page.evaluate!(page, ~s|window["__inlineScriptValue"]|) == nil
    Page.add_script_tag(page, content: ~s|window["__injected"] = 42;|)
    assert Page.evaluate!(page, ~s|window["__injected"]|) == nil
    BrowserContext.close!(context)

    # By-pass CSP and try one more time.
    context = Browser.new_context!(browser, bypass_csp: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/csp.html")
    assert Page.evaluate!(page, ~s|window["__inlineScriptValue"]|) == 42
    Page.add_script_tag!(page, content: ~s|window["__injected"] = 42;|)
    assert Page.evaluate!(page, ~s|window["__injected"]|) == 42
    BrowserContext.close!(context)
  end

  test "CS-002 should bypass CSP header", %{browser: browser, server: server} do
    # Make sure CSP prohibits addScriptTag.
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-security-policy", ~s|default-src "self"|)
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<script type='text/javascript'>window.__inlineScriptValue = 42;</script>")
    end)

    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, ~s|window["__inlineScriptValue"]|) == nil
    Page.add_script_tag(page, content: ~s|window["__injected"] = 42;|)
    assert Page.evaluate!(page, ~s|window["__injected"]|) == nil
    BrowserContext.close!(context)

    # By-pass CSP and try one more time.
    context = Browser.new_context!(browser, bypass_csp: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, ~s|window["__inlineScriptValue"]|) == 42
    Page.add_script_tag!(page, content: ~s|window["__injected"] = 42;|)
    assert Page.evaluate!(page, ~s|window["__injected"]|) == 42
    BrowserContext.close!(context)
  end

  test "CS-003 should bypass after cross-process navigation", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, bypass_csp: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/csp.html")
    assert Page.evaluate!(page, ~s|window["__inlineScriptValue"]|) == 42
    Page.add_script_tag!(page, content: ~s|window["__injected"] = 42;|)
    assert Page.evaluate!(page, ~s|window["__injected"]|) == 42

    Page.goto!(page, server.cross_process_prefix <> "/csp.html")
    assert Page.evaluate!(page, ~s|window["__inlineScriptValue"]|) == 42
    Page.add_script_tag!(page, content: ~s|window["__injected"] = 42;|)
    assert Page.evaluate!(page, ~s|window["__injected"]|) == 42
    BrowserContext.close!(context)
  end

  test "CS-004 should bypass CSP in iframes as well", %{browser: browser, server: server} do
    # Make sure CSP prohibits addScriptTag in an iframe.
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    frame = attach_frame(page, "frame1", server.prefix <> "/csp.html")
    assert Frame.evaluate!(frame, ~s|window["__inlineScriptValue"]|) == nil
    Frame.add_script_tag(frame, content: ~s|window["__injected"] = 42;|)
    assert Frame.evaluate!(frame, ~s|window["__injected"]|) == nil
    BrowserContext.close!(context)

    # By-pass CSP and try one more time.
    context = Browser.new_context!(browser, bypass_csp: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    frame = attach_frame(page, "frame1", server.prefix <> "/csp.html")
    assert Frame.evaluate!(frame, ~s|window["__inlineScriptValue"]|) == 42
    Frame.add_script_tag(frame, content: ~s|window["__injected"] = 42;|)
    assert Frame.evaluate!(frame, ~s|window["__injected"]|) == 42
    BrowserContext.close!(context)
  end

  test "CS-005 should not crash on javascript: navigation", %{browser: browser, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43213' });
    context = Browser.new_context!(browser, bypass_csp: true)
    page = BrowserContext.new_page!(context)
    test = self()
    Page.on(page, :crash, fn _ -> send(test, :crashed) end)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s|<a id="a" href="javascript:window.__clicked = true">click</a>|)
    Page.click!(page, "#a")
    Utils.poll(fn -> Page.evaluate!(page, ~s|() => window['__clicked']|) end, &assert(&1 == true))
    refute_received :crashed
    BrowserContext.close!(context)
  end
end
