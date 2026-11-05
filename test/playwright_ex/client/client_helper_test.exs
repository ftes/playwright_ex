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
    assert Task.await(task).assigns.post_body == ~s({"a":null})

    PlaywrightEx.TestServer.set_route(server, "/null.json", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, "null")
    end)

    response = APIRequestContext.get!(request, server.prefix <> "/null.json")
    assert APIResponse.json!(response) == :null
  end
end
