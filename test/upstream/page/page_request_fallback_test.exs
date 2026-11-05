defmodule PlaywrightEx.Page.PageRequestFallbackTest do
  @upstream "tests/page/page-request-fallback.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  # `const intercepted = []; ... intercepted.push(x)`: the handlers send to the test process.
  defp received(acc \\ []) do
    receive do
      {:intercepted, x} -> received([x | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "should work", %{page: page, server: server} do
    Page.route!(page, "**/*", &Route.fallback/1)
    Page.goto!(page, server.empty_page)
  end

  test "should fall back", %{page: page, server: server} do
    me = self()

    for i <- 1..3 do
      Page.route!(page, "**/empty.html", fn route ->
        send(me, {:intercepted, i})
        Route.fallback(route)
      end)
    end

    Page.goto!(page, server.empty_page)
    assert received() == [3, 2, 1]
  end

  test "should fall back async", %{page: page, server: server} do
    me = self()

    for i <- 1..3 do
      Page.route!(page, "**/empty.html", fn route ->
        send(me, {:intercepted, i})
        Page.wait_for_timeout!(page, 100)
        Route.fallback(route)
      end)
    end

    Page.goto!(page, server.empty_page)
    assert received() == [3, 2, 1]
  end

  test "should not chain fulfill", %{page: page, server: server} do
    me = self()
    Page.route!(page, "**/empty.html", fn _route -> send(me, :failed) end)
    Page.route!(page, "**/empty.html", fn route -> Route.fulfill(route, status: 200, body: "fulfilled") end)
    Page.route!(page, "**/empty.html", &Route.fallback/1)
    response = Page.goto!(page, server.empty_page)
    body = Response.body!(response)
    assert body == "fulfilled"
    refute_received :failed
  end

  test "should not chain abort", %{page: page, server: server} do
    me = self()
    Page.route!(page, "**/empty.html", fn _route -> send(me, :failed) end)
    Page.route!(page, "**/empty.html", &Route.abort/1)
    Page.route!(page, "**/empty.html", &Route.fallback/1)
    assert {:error, e} = Page.goto(page, server.empty_page)
    assert e
    refute_received :failed
  end

  test "should fall back after exception", %{page: page, server: server} do
    Page.route!(page, "**/empty.html", &Route.continue/1)

    Page.route!(page, "**/empty.html", fn route ->
      try do
        # `response: {} as any`: not an APIResponse, so ignored (as in JS).
        Route.fulfill!(route, response: %{})
      rescue
        _ -> Route.fallback(route)
      end
    end)

    Page.goto!(page, server.empty_page)
  end

  test "should chain once", %{page: page, server: server} do
    Page.route!(page, "**/empty.html", fn route -> Route.fulfill(route, status: 200, body: "fulfilled one") end,
      times: 1
    )

    Page.route!(page, "**/empty.html", &Route.fallback/1, times: 1)
    response = Page.goto!(page, server.empty_page)
    body = Response.body!(response)
    assert body == "fulfilled one"
  end

  test "should amend HTTP headers", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/sleep.zzz", fn route ->
      send(me, {:intercepted, Request.headers(Route.request(route))["foo"]})
      send(me, {:intercepted, Request.header_value!(Route.request(route), "FOO")})
      Route.continue(route)
    end)

    Page.route!(page, "**/*", fn route ->
      Route.fallback(route, headers: Map.put(Request.headers(Route.request(route)), "FOO", "bar"))
    end)

    Page.goto!(page, server.empty_page)
    server_request = TestServer.wait_for_request(server, "/sleep.zzz")
    Page.evaluate!(page, "() => fetch('/sleep.zzz')")
    request = Task.await(server_request, :infinity)
    values = received() ++ [Plug.Conn.get_req_header(request, "foo") |> List.first()]
    assert values == ["bar", "bar", "bar"]
  end

  test "should delete header with undefined value", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")

    TestServer.set_route(server, "/something", fn conn ->
      conn |> Plug.Conn.put_resp_header("access-control-allow-origin", "*") |> Plug.Conn.send_resp(200, "done")
    end)

    me = self()

    Page.route!(page, "**/*", fn route, request ->
      send(me, {:intercepted_request, request})
      Route.continue(route)
    end)

    Page.route!(page, server.prefix <> "/something", fn route, request ->
      headers = Request.all_headers!(request)
      Route.fallback(route, headers: Map.put(headers, "foo", nil))
    end)

    server_request = TestServer.wait_for_request(server, "/something")

    text =
      Page.evaluate!(
        page,
        """
        async url => {
          const data = await fetch(url, {
            headers: {
              foo: 'a',
              bar: 'b',
            }
          });
          return data.text();
        }
        """,
        server.prefix <> "/something"
      )

    server_request = Task.await(server_request, :infinity)
    assert text == "done"
    assert_received {:intercepted_request, intercepted_request}
    assert Request.headers(intercepted_request)["foo"] == nil
    assert Request.headers(intercepted_request)["bar"] == "b"
    assert Plug.Conn.get_req_header(server_request, "foo") == []
    assert Plug.Conn.get_req_header(server_request, "bar") == ["b"]
  end

  test "should amend method", %{page: page, server: server} do
    s_request = TestServer.wait_for_request(server, "/sleep.zzz")
    Page.goto!(page, server.empty_page)
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:method, Request.method(Route.request(route))})
      Route.continue(route)
    end)

    Page.route!(page, "**/*", &Route.fallback(&1, method: "POST"))

    request =
      Page.expect_request!(page, "**/sleep.zzz", fn -> Page.evaluate!(page, "() => fetch('/sleep.zzz')") end)

    assert_received {:method, "POST"}
    assert Request.method(request) == "POST"
    assert Task.await(s_request, :infinity).method == "POST"
  end

  test "should override request url", %{page: page, server: server} do
    server_request = TestServer.wait_for_request(server, "/global-var.html")
    me = self()

    Page.route!(page, "**/global-var.html", fn route ->
      send(me, {:url, Request.url(Route.request(route))})
      Route.continue(route)
    end)

    Page.route!(page, "**/foo", &Route.fallback(&1, url: server.prefix <> "/global-var.html"))

    response = Page.goto!(page, server.prefix <> "/foo")
    url = server.prefix <> "/global-var.html"
    assert_received {:url, ^url}
    assert Request.url(Response.request(response)) == server.prefix <> "/global-var.html"
    assert Response.url(response) == server.prefix <> "/global-var.html"
    assert Page.evaluate!(page, "() => window['globalVar']") == 123
    assert Task.await(server_request, :infinity).method == "GET"
  end

  describe "post data" do
    test "should amend post data", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      me = self()

      Page.route!(page, "**/*", fn route ->
        send(me, {:post_data, Request.post_data(Route.request(route))})
        Route.continue(route)
      end)

      Page.route!(page, "**/*", &Route.fallback(&1, post_data: "doggo"))
      server_request = TestServer.wait_for_request(server, "/sleep.zzz")
      Page.evaluate!(page, "() => fetch('/sleep.zzz', { method: 'POST', body: 'birdy' })")
      server_request = Task.await(server_request, :infinity)
      assert_received {:post_data, "doggo"}
      assert server_request.assigns.post_body == "doggo"
    end

    test "should amend binary post data", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      arr = :binary.list_to_bin(Enum.to_list(0..255))
      me = self()

      Page.route!(page, "**/*", fn route ->
        send(me, {:post_data_buffer, Request.post_data_buffer(Route.request(route))})
        Route.continue(route)
      end)

      Page.route!(page, "**/*", &Route.fallback(&1, post_data: {:binary, arr}))
      server_request = TestServer.wait_for_request(server, "/sleep.zzz")
      Page.evaluate!(page, "() => fetch('/sleep.zzz', { method: 'POST', body: 'birdy' })")
      buffer = Task.await(server_request, :infinity).assigns.post_body
      assert_received {:post_data_buffer, post_data_buffer}
      assert byte_size(post_data_buffer) == byte_size(arr)
      assert byte_size(buffer) == byte_size(arr)
      assert buffer == arr
      assert post_data_buffer == arr
    end

    test "should amend json post data", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      me = self()

      Page.route!(page, "**/*", fn route ->
        send(me, {:post_data, Request.post_data_json(Route.request(route))})
        Route.continue(route)
      end)

      Page.route!(page, "**/*", &Route.fallback(&1, post_data: %{foo: "bar"}))
      server_request = TestServer.wait_for_request(server, "/sleep.zzz")
      Page.evaluate!(page, "() => fetch('/sleep.zzz', { method: 'POST', body: 'birdy' })")
      server_request = Task.await(server_request, :infinity)
      assert_received {:post_data, %{"foo" => "bar"}}
      assert server_request.assigns.post_body == ~s({"foo":"bar"})
    end
  end
end
