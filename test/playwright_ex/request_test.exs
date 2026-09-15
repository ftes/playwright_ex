defmodule PlaywrightEx.RequestTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection
  alias PlaywrightEx.EventWaiter
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Request

  setup %{browser_context: context} do
    connection = PlaywrightEx.Supervisor.Connection
    :ok = Connection.subscribe_sync(connection, self(), context.guid)

    {:ok, _} = BrowserContext.update_subscription(context.guid, event: :response, enabled: false, timeout: @timeout)

    command(context.guid, :set_network_interception_patterns, %{patterns: [%{glob: "https://request.test/**"}]})

    %{connection: connection}
  end

  test "retrieves an earlier navigation response after a later navigation", %{
    frame: frame,
    connection: connection
  } do
    {:ok, waiter} = EventWaiter.arm(frame.guid, :navigated, timeout: @timeout)
    navigation = navigate(frame, "/first")
    %{route: first} = routed_request()
    fulfill(first, 201)
    assert {:ok, _} = Task.await(navigation)

    navigation = navigate(frame, "/later")
    %{route: later} = routed_request()
    fulfill(later, 202)
    assert {:ok, _} = Task.await(navigation)

    {:ok, %{params: %{new_document: %{request: request}}}} = EventWaiter.await(waiter)
    assert {:ok, response} = Request.response(request.guid, connection: Process.whereis(connection), timeout: :infinity)
    assert %{status: 201, url: "https://request.test/first"} = Connection.initializer!(connection, response.guid)
  end

  test "waits for a pending response and returns HTTP error responses", %{frame: frame, connection: connection} do
    navigation = navigate(frame, "/pending")
    %{route: route, request: request} = routed_request()
    response = Task.async(fn -> Request.response(request.guid, timeout: @timeout) end)
    assert Task.yield(response, 20) == nil

    fulfill(route, 503)
    assert {:ok, response} = Task.await(response)
    assert %{status: 503} = Connection.initializer!(connection, response.guid)
    assert {:ok, _} = Task.await(navigation)
  end

  test "returns nil when a request fails without a response", %{frame: frame} do
    navigation = navigate(frame, "/failed")
    %{route: route, request: request} = routed_request()

    command(route.guid, :abort, %{error_code: "failed"})

    assert {:error, _} = Task.await(navigation)
    assert {:ok, nil} = Request.response(request.guid, timeout: @timeout)
  end

  test "uses the standard zero and finite timeouts for pending responses", %{frame: frame} do
    navigation = navigate(frame, "/timeout")
    %{route: route, request: request} = routed_request()
    assert {:error, %{reason: :timeout}} = Request.response(request.guid, timeout: 0)
    assert {:error, %{error: %{name: "TimeoutError"}}} = Request.response(request.guid, timeout: 20)

    fulfill(route, 200)
    assert {:ok, _} = Task.await(navigation)
    assert {:ok, %{guid: _}} = Request.response(request.guid, timeout: @timeout)
  end

  defp navigate(frame, path) do
    Task.async(fn -> Frame.goto(frame.guid, url: "https://request.test" <> path, timeout: @timeout) end)
  end

  defp routed_request do
    assert_receive {:playwright_msg, %{method: :route, params: params}}, @timeout
    Map.put(params, :request, Connection.initializer!(PlaywrightEx.Supervisor.Connection, params.route.guid).request)
  end

  defp fulfill(route, status) do
    command(route.guid, :fulfill, %{status: status, headers: [], body: "<h1>Response</h1>", is_base64: false})
  end

  defp command(guid, method, params) do
    assert {:ok, _} =
             PlaywrightEx.Supervisor.Connection
             |> Connection.send(%{guid: guid, method: method, params: params}, @timeout)
             |> ChannelResponse.unwrap(& &1)
  end
end
