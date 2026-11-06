defmodule PlaywrightEx.Client.ClientHelperTest do
  # Not mirrored from upstream: the Elixir-only JS helpers (`null`, truthiness, `String(number)`) end to end.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route

  test "json_stringify: :null is null, nil (undefined) is dropped from objects" do
    assert ClientHelper.json_stringify(:null) == "null"

    assert JSON.decode!(ClientHelper.json_stringify(%{a: :null, b: nil, c: [:null, 1]})) == %{
             "a" => nil,
             "c" => [nil, 1]
           }
  end

  test "json_stringify_indented: a scheme gives JS's key order" do
    state = %{
      origins: [%{localStorage: [%{value: "v", name: "n"}], origin: "o"}],
      cookies: [
        %{secure: false, name: "a", value: "b", domain: "d", path: "/", expires: -1, httpOnly: false, sameSite: "Lax"}
      ]
    }

    json = ClientHelper.json_stringify_indented(state, 2, "BrowserContextStorageStateResult")
    keys = Regex.scan(~r/"(\w+)":/, json, capture: :all_but_first) |> List.flatten()

    assert keys ==
             ~w(cookies name value domain path expires httpOnly secure sameSite origins origin localStorage name value)

    assert ClientHelper.json_parse(json) == JSON.decode!(JSON.encode!(state))
  end

  test "json_parse: null is :null, invalid JSON raises" do
    assert ClientHelper.json_parse("null") == :null
    assert ClientHelper.json_parse(~s( {"a": null, "b": [null, 1]} )) == %{"a" => :null, "b" => [:null, 1]}
    assert_raise JSON.DecodeError, fn -> ClientHelper.json_parse("null x") end
    assert_raise JSON.DecodeError, fn -> ClientHelper.json_parse("<not a json>") end
  end

  test "truthy: JS falsy values" do
    for value <- [nil, false, :null, "", 0, +0.0, -0.0], do: refute(ClientHelper.truthy(value))
    for value <- [true, "a", 1, %{}, [], :atom], do: assert(ClientHelper.truthy(value))
  end

  test "number_to_string: as JS String(number)" do
    assert ClientHelper.number_to_string(100) == "100"
    assert ClientHelper.number_to_string(100.0) == "100"
    assert ClientHelper.number_to_string(-0.0) == "0"
    assert ClientHelper.number_to_string(8.5) == "8.5"
  end

  # Expected values are Node's `String(x)` (the driver's node).
  test "number_to_string: exponent form and shortest digits, as JS Number::toString" do
    for {number, expected} <- [
          {0, "0"},
          {0.0, "0"},
          {-0.0, "0"},
          {1.0e21, "1e+21"},
          {1.0e-7, "1e-7"},
          {123.456, "123.456"},
          {2 ** 53, "9007199254740992"},
          {2 ** 53 + 2, "9007199254740994"},
          {2 ** 60, "1152921504606847000"},
          {1.0e300, "1e+300"},
          {5.0e-324, "5e-324"},
          {123.0e20, "1.23e+22"},
          {1.0e20, "100000000000000000000"},
          {123_456_789_012_345_680_000, "123456789012345680000"},
          {1.0e-6, "0.000001"},
          {0.000001234, "0.000001234"},
          {-1.5e-10, "-1.5e-10"},
          {0.1, "0.1"},
          {-123.456e25, "-1.23456e+27"},
          {1.5e21, "1.5e+21"},
          {1.7_976_931_348_623_157e308, "1.7976931348623157e+308"},
          {:nan, "NaN"},
          {:neg_infinity, "-Infinity"}
        ] do
      assert ClientHelper.number_to_string(number) == expected, "String(#{inspect(number)})"
    end
  end

  @tag :page
  test "fulfill json: :null sends null and response.json() is :null", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route -> Route.fulfill!(route, json: :null) end)
    response = Page.goto!(page, server.empty_page)
    assert Response.text!(response) == "null"
    assert Response.json!(response) == :null
    # `options.json` is falsy: no JSON content type, as in JS.
    refute Response.headers(response)["content-type"] == "application/json"
  end

  @tag :page
  test "postDataJSON() of a null body is :null", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    request = Page.wait_for_request(page, "**/title.html")
    Page.evaluate!(page, "url => fetch(url, { method: 'POST', body: 'null' })", server.prefix <> "/title.html")
    assert Request.post_data_json(Promise.await!(request)) == :null
  end

  @tag request: %{}
  test "APIResponse.json() of null is :null and data: %{a: :null} is JSON null", %{request: request, server: server} do
    task = PlaywrightEx.TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.post!(request, server.empty_page, data: %{a: :null})
    assert Task.await(task, :infinity).assigns.post_body == ~s({"a":null})

    PlaywrightEx.TestServer.set_route(server, "/null.json", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, "null")
    end)

    response = APIRequestContext.get!(request, server.prefix <> "/null.json")
    assert APIResponse.json!(response) == :null
  end
end
