defmodule PlaywrightEx.Page.PageRequestInterceptTest do
  @upstream "tests/page/page-request-intercept.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  # rewriteAndroidLoopbackURL  -- not ported: only used by the route.fetch tests

  @tag skip: "not ported: fetch"
  test "should fulfill intercepted response"

  @tag skip: "not ported: fetch"
  test "should fulfill response with empty body"

  @tag skip: "not ported: fetch"
  test "should override with defaults when intercepted response not provided"

  @tag skip: "not ported: fetch"
  test "should fulfill with any response"

  @tag skip: "not ported: fetch"
  test "should support fulfill after intercept"

  @tag skip: "not ported: fetch"
  test "should give access to the intercepted response"

  @tag skip: "not ported: fetch"
  test "should give access to the intercepted response body"

  # it.fixme(browserName !== 'firefox')
  @tag skip: "upstream fixme"
  test "should intercept multipart/form-data request body"

  @tag skip: "not ported: fetch"
  test "should fulfill intercepted response using alias"

  @tag skip: "not ported: fetch"
  test "should support timeout option in route.fetch"

  @tag skip: "not ported: fetch"
  test "should not follow redirects when maxRedirects is set to 0 in route.fetch"

  @tag skip: "not ported: fetch"
  test "should intercept with url override"

  @tag skip: "not ported: fetch"
  test "should intercept with post data override"

  test "request.postData is not null when fetching FormData with a Blob", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    if browser_name != "webkit" do
      Page.goto!(page, server.empty_page)

      Page.set_content!(page, """

      <script>
        function doStuff() {
          const formData = new FormData();
          formData.append('file', new Blob(["hello"], { type: "text/plain" }));
          fetch('/upload', {
            method: 'POST',
            body: formData
          });
        }
      </script>
      <body>
      <button onclick="doStuff()" data-testid="click-me">Click me!</button>
      </body>
      """)

      me = self()

      Page.route!(page, server.prefix <> "/upload", fn route, request ->
        send(me, {:method, Request.method(request)})
        send(me, {:post_data, Request.post_data(request)})
        Route.fulfill!(route, status: 200, body: "ok")
      end)

      page |> Page.get_by_test_id("click-me") |> Locator.click!()
      assert_receive {:post_data, post_data}, 5000
      assert_received {:method, "POST"}
      assert post_data =~ ~s(Content-Disposition: form-data; name="file"; filename="blob")
      assert post_data =~ "\r\nhello\r\n"
    end
  end

  test "should abort favicon requests if interception is enabled", %{page: page, server: server} do
    me = self()

    TestServer.set_route(server, "/favicon.ico", fn conn ->
      send(me, :favicon_request)
      conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.send_resp(200, "my content")
    end)

    # Intercept all requests.
    Page.route!(page, "**/*", &Route.fulfill!(&1, status: 200, body: "Hello, world!"))
    Page.goto!(page, server.empty_page)
    response = Page.evaluate!(page, "() => fetch('/favicon.ico').then(r => r.text()).catch(e => 'load failed')")
    assert response == "load failed"
    # Browsers can send favicon requests in the background.
    Process.sleep(1000)
    refute_received :favicon_request
  end
end
