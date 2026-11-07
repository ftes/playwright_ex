defmodule PlaywrightEx.Page.FirefoxNetworkResponseTest do
  @upstream "tests/page/firefox-network-response.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  # it.skip(({ browserName, isBidi }) => browserName !== 'firefox' || isBidi, 'Tests the Firefox network observer.');
  @moduletag skip:
               if(System.get_env("BROWSER", "chromium") != "firefox",
                 do: "upstream skip: Tests the Firefox network observer."
               )

  defp expect_header_fields(response, expected) do
    headers = Response.headers_array!(response)
    all_headers = Response.all_headers!(response)

    for name <- expected |> Enum.map(&String.downcase(&1.name)) |> Enum.uniq() do
      fields = Enum.filter(expected, &(String.downcase(&1.name) == name))
      values = Enum.map(fields, & &1.value)
      assert Enum.filter(headers, &(String.downcase(&1.name) == name)) == fields
      assert Response.header_values!(response, name) == values
      combined = Enum.join(values, if(name == "set-cookie", do: "\n", else: ", "))
      assert Response.header_value!(response, name) == combined
      assert all_headers[name] == combined
    end
  end

  # `Promise.all([page.waitForResponse(url), page.evaluate(...)])`
  defp fetch_response(page, url) do
    response = Page.wait_for_response(page, url)

    fetched =
      Page.evaluate!(
        page,
        """
        async url => {
          const response = await fetch(url);
          return { status: response.status, body: await response.text() };
        }
        """,
        url
      )

    %{response: Promise.await!(response), fetched: fetched}
  end

  # `response.writeHead(status, headers)` keeps the header names and order as given (Plug's
  # `put_resp_header/3` takes lower-case names only).
  defp write_head(conn, status, headers, body \\ "") do
    Plug.Conn.send_resp(%{conn | resp_headers: headers}, status, body)
  end

  for status <- [200, 302] do
    @status status
    test "FF-005 should preserve original response header fields for #{status} responses", %{page: page, server: server} do
      status = @status

      # Deviation: upstream sends `Date`; Bandit adds its own `date` unless the response has one
      # spelled in lower case.
      headers = [
        %{name: "date", value: "Wed, 21 Oct 2037 07:28:00 GMT"},
        %{name: "X-Literal", value: ~s(first, "second, third")},
        %{name: "X-Identical", value: "same"},
        %{name: "X-Identical", value: "same"},
        %{name: "X-Repeat", value: "first, literal"},
        %{name: "x-repeat", value: "second"},
        %{name: "Set-Cookie", value: "a=b; Expires=Wed, 21 Oct 2037 07:28:00 GMT"},
        %{name: "Set-Cookie", value: "c=d; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/"},
        %{name: "WWW-Authenticate", value: ~s(Digest realm="one, two", qop="auth, auth-int")},
        %{name: "WWW-Authenticate", value: ~s(Basic realm="three, four")},
        %{name: "Proxy-Authenticate", value: ~s(Basic realm="five, six")},
        %{name: "Proxy-Authenticate", value: ~s(Basic realm="five, six")}
      ]

      TestServer.set_route(server, "/headers", fn conn ->
        write_head(
          conn,
          status,
          [{"Content-Type", "text/html"}] ++
            if(status == 302, do: [{"Location", "/empty.html"}], else: []) ++
            Enum.map(headers, &{&1.name, &1.value}),
          "body"
        )
      end)

      final_response = Page.goto!(page, server.prefix <> "/headers")

      response =
        if status == 302,
          do: final_response |> Response.request() |> Request.redirected_from() |> Request.response!(),
          else: final_response

      assert Response.status(response) == status
      expect_header_fields(response, headers)
    end
  end

  test "FF-006 should preserve synthesized response header fields", %{page: page, server: server} do
    cookies = [
      "a=b; Expires=Wed, 21 Oct 2037 07:28:00 GMT",
      "c=d; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/"
    ]

    Page.route!(page, "**/headers", fn route ->
      Route.fulfill(route,
        content_type: "text/html",
        headers: %{
          "X-Literal" => ~s(first, "second, third"),
          "Date" => "Wed, 21 Oct 2037 07:28:00 GMT",
          "Set-Cookie" => Enum.join(cookies, "\n"),
          "WWW-Authenticate" => ~s(Digest realm="one, two", qop="auth, auth-int")
        },
        body: "fulfilled"
      )
    end)

    response = Page.goto!(page, server.prefix <> "/headers")
    assert Response.text!(response) == "fulfilled"

    expect_header_fields(
      response,
      [
        %{name: "x-literal", value: ~s(first, "second, third")},
        %{name: "date", value: "Wed, 21 Oct 2037 07:28:00 GMT"}
      ] ++
        Enum.map(cookies, &%{name: "set-cookie", value: &1}) ++
        [%{name: "www-authenticate", value: ~s(Digest realm="one, two", qop="auth, auth-int")}]
    )
  end

  test "FF-007 should report current effective fields after cache revalidation", %{page: page, server: server} do
    {:ok, validators} = Agent.start_link(fn -> [] end)

    TestServer.set_route(server, "/cached-headers", fn conn ->
      validator = conn |> Plug.Conn.get_req_header("if-none-match") |> List.first()
      Agent.update(validators, &(&1 ++ [validator]))

      if Agent.get(validators, &length/1) == 1 do
        write_head(
          conn,
          200,
          [
            {"Content-Type", "text/plain"},
            {"ETag", ~s("v1")},
            {"Cache-Control", "max-age=0, must-revalidate"},
            {"X-Keep", "first, literal"},
            {"X-Keep", "second"},
            {"X-Change", "old, literal"},
            {"X-Change", "old-second"},
            {"Set-Cookie", "old=value; Expires=Wed, 21 Oct 2037 07:28:00 GMT"},
            {"Set-Cookie", "old2=value; Path=/"},
            {"WWW-Authenticate", ~s(Basic realm="old, realm")},
            {"WWW-Authenticate", ~s(Basic realm="old-second")},
            {"Proxy-Authenticate", ~s(Basic realm="old, proxy")},
            {"Proxy-Authenticate", ~s(Basic realm="old-proxy-second")}
          ],
          "cached-body"
        )
      else
        write_head(conn, 304, [
          {"Cache-Control", "max-age=3600"},
          {"X-Change", "new, literal"},
          {"X-Change", "new-second"},
          {"Set-Cookie", "new=value; Expires=Wed, 21 Oct 2037 07:28:00 GMT"},
          {"Set-Cookie", "new2=value; Path=/"},
          {"WWW-Authenticate", ~s(Basic realm="new, realm")},
          {"WWW-Authenticate", ~s(Basic realm="new-second")},
          {"Proxy-Authenticate", ~s(Basic realm="new, proxy")},
          {"Proxy-Authenticate", ~s(Basic realm="new-proxy-second")}
        ])
      end
    end)

    Page.goto!(page, server.empty_page)
    url = server.prefix <> "/cached-headers"
    initial = fetch_response(page, url)
    revalidated = fetch_response(page, url)
    cached = fetch_response(page, url)

    assert Agent.get(validators, & &1) == [nil, ~s("v1")]

    for %{fetched: fetched} <- [initial, revalidated, cached],
        do: assert(fetched == %{"status" => 200, "body" => "cached-body"})

    assert [Response.status(initial.response), Response.status(revalidated.response), Response.status(cached.response)] ==
             [200, 304, 200]

    assert Response.header_value!(initial.response, "x-change") == "old, literal, old-second"
    assert Response.header_values!(revalidated.response, "x-keep") == []
    assert Response.header_values!(revalidated.response, "x-change") == ["new, literal", "new-second"]

    assert Response.header_values!(revalidated.response, "set-cookie") == [
             "new=value; Expires=Wed, 21 Oct 2037 07:28:00 GMT",
             "new2=value; Path=/"
           ]

    assert Response.header_values!(revalidated.response, "www-authenticate") ==
             [~s(Basic realm="new, realm"), ~s(Basic realm="new-second")]

    assert Response.header_values!(revalidated.response, "proxy-authenticate") ==
             [~s(Basic realm="new, proxy"), ~s(Basic realm="new-proxy-second")]

    assert Response.header_values!(cached.response, "x-keep") == ["first, literal, second"]
    assert Response.header_values!(cached.response, "x-change") == ["new, literal, new-second"]

    for name <- ["set-cookie", "www-authenticate", "proxy-authenticate"],
        do: assert(Response.header_values!(cached.response, name) == [])
  end

  test "FF-008 should report a standalone 304 response without waiting for a cache merge", %{page: page, server: server} do
    TestServer.set_route(server, "/standalone-304", fn conn ->
      write_head(conn, 304, [{"X-Literal", "standalone, value"}, {"Cache-Control", "no-store"}])
    end)

    Page.goto!(page, server.empty_page)
    %{response: response, fetched: fetched} = fetch_response(page, server.prefix <> "/standalone-304")
    assert Response.status(response) == 304
    assert fetched == %{"status" => 304, "body" => ""}
    assert Response.header_values!(response, "x-literal") == ["standalone, value"]
    assert Response.finished!(response) == nil
  end
end
