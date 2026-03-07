defmodule PlaywrightEx.Resource.FrameTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Connection
  alias PlaywrightEx.Resource.Frame
  alias PlaywrightEx.Resource.Page

  defmodule DummyTransport do
    @moduledoc false
    @behaviour PlaywrightEx.Transport

    @impl PlaywrightEx.Transport
    def post(_name, _msg), do: :ok
  end

  test "starts one resource per {connection, frame}" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()

    assert_eventually(fn ->
      match?(
        [{_pid, _}],
        Registry.lookup(Frame.registry_name(connection), frame_id)
      )
    end)

    assert {:ok, pid1} = Frame.ensure_started(connection, frame_id)
    assert {:ok, pid2} = Frame.ensure_started(connection, frame_id)
    assert pid1 == pid2
  end

  test "await_url waits for navigated + loadstate events" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()

    task =
      Task.async(fn ->
        Frame.await_url(
          connection,
          frame_id,
          &(&1 == "about:blank#done"),
          "load",
          500
        )
      end)

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :navigated, params: %{url: "about:blank#done"}})

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{add: "load"}})

    assert {:ok, nil} = Task.await(task, 1_000)
  end

  test "waiters fail when frame is disposed" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    frame_resource = frame_resource_pid!(connection, frame_id)

    task =
      Task.async(fn ->
        Frame.await_url(connection, frame_id, &(&1 == "about:blank#never"), "load", 500)
      end)

    assert_eventually(fn ->
      map_size(:sys.get_state(frame_resource).waiters) == 1
    end)

    Connection.handle_playwright_msg(connection, %{method: :__dispose__, guid: frame_id})

    assert {:error, %{message: "Navigating frame was detached!"}} = Task.await(task, 1_000)
  end

  test "waiters fail fast when page crashes" do
    %{connection: connection, frame_id: frame_id, page_id: page_id} = start_connection_with_frame!()
    frame_resource = frame_resource_pid!(connection, frame_id)

    task =
      Task.async(fn ->
        Frame.await_url(connection, frame_id, &(&1 == "about:blank#never"), "load", 500)
      end)

    assert_eventually(fn ->
      map_size(:sys.get_state(frame_resource).waiters) == 1
    end)

    Connection.handle_playwright_msg(connection, %{guid: page_id, method: :crash, params: %{}})

    assert {:error, %{message: "Navigation failed because page crashed!"}} = Task.await(task, 1_000)
  end

  test "waiters fail fast when page is closed" do
    %{connection: connection, frame_id: frame_id, page_id: page_id} = start_connection_with_frame!()
    frame_resource = frame_resource_pid!(connection, frame_id)

    task =
      Task.async(fn ->
        Frame.await_url(connection, frame_id, &(&1 == "about:blank#never"), "load", 500)
      end)

    assert_eventually(fn ->
      map_size(:sys.get_state(frame_resource).waiters) == 1
    end)

    Connection.handle_playwright_msg(connection, %{method: :__dispose__, guid: page_id})

    assert {:error, %{message: "Navigation failed because page was closed!"}} = Task.await(task, 1_000)
  end

  test "info and events expose generic resource state" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()

    Connection.handle_playwright_msg(connection, %{
      guid: frame_id,
      method: :navigated,
      params: %{url: "about:blank#event"}
    })

    assert_eventually(fn ->
      match?(
        %{id: ^frame_id, status: :open, page_id: "page-1", url: "about:blank#event"},
        Frame.info(connection, frame_id)
      )
    end)

    assert [%{method: :__create__}, %{method: :navigated}] = Frame.events(connection, frame_id, 10)
    assert %{} = Frame.child_resources(connection, frame_id)
  end

  defp start_connection_with_frame! do
    connection = String.to_atom("frame_resource_connection_#{System.unique_integer([:positive])}")
    scope = String.to_atom("frame_resource_scope_#{System.unique_integer([:positive])}")
    frame_id = "frame-1"
    page_id = "page-1"

    {:ok, _} = :pg.start_link(scope)
    {:ok, _} = Registry.start_link(keys: :unique, name: Page.registry_name(connection))
    {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: Page.supervisor_name(connection))
    {:ok, _} = Registry.start_link(keys: :unique, name: Frame.registry_name(connection))
    {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: Frame.supervisor_name(connection))

    {:ok, _pid} =
      Connection.start_link(
        name: connection,
        timeout: 1_000,
        transport: {DummyTransport, :dummy},
        js_logger: nil,
        pg_scope: scope
      )

    Connection.handle_playwright_msg(connection, %{method: :__create__, params: %{guid: "Playwright", initializer: %{}}})

    assert_eventually(fn ->
      match?({:started, _}, :sys.get_state(connection))
    end)

    Connection.handle_playwright_msg(connection, %{
      method: :__create__,
      params: %{guid: page_id, initializer: %{main_frame: %{guid: frame_id}}}
    })

    Connection.handle_playwright_msg(connection, %{
      method: :__create__,
      params: %{
        guid: frame_id,
        initializer: %{url: "about:blank", load_states: ["commit"], page: %{guid: page_id}}
      }
    })

    assert_eventually(fn ->
      case safe_initializer(connection, frame_id) do
        {:ok, _initializer} -> true
        _ -> false
      end
    end)

    %{connection: connection, frame_id: frame_id, page_id: page_id}
  end

  defp safe_initializer(connection, frame_id) do
    {:ok, Connection.initializer!(connection, frame_id)}
  catch
    :exit, _reason -> :error
  end

  defp frame_resource_pid!(connection, frame_id) do
    [{pid, _}] = Registry.lookup(Frame.registry_name(connection), frame_id)
    pid
  end

  defp assert_eventually(fun, attempts \\ 20)
  defp assert_eventually(fun, attempts) when attempts <= 0, do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
