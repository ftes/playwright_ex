defmodule PlaywrightEx.Resource.PageTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Connection
  alias PlaywrightEx.Resource.Page

  defmodule DummyTransport do
    @moduledoc false
    @behaviour PlaywrightEx.Transport

    @impl PlaywrightEx.Transport
    def post(_name, _msg), do: :ok
  end

  test "starts one resource per {connection, page}" do
    %{connection: connection, page_id: page_id} = start_connection_with_page!()

    assert {:ok, pid1} = Page.ensure_started(connection, page_id)
    assert {:ok, pid2} = Page.ensure_started(connection, page_id)
    assert pid1 == pid2
  end

  test "tracks child resources and exposes generic info" do
    %{connection: connection, page_id: page_id, frame_id: frame_id} = start_connection_with_page!()

    Connection.handle_playwright_msg(connection, %{
      guid: page_id,
      method: :__create__,
      params: %{guid: "dialog-1", type: "Dialog", initializer: %{message: "Are you sure?"}}
    })

    assert_eventually(fn ->
      match?(
        %{
          id: ^page_id,
          status: :open,
          main_frame_id: ^frame_id,
          recent_events_count: 2,
          child_resources: %{frame: [%{guid: ^frame_id}], dialog: [%{guid: "dialog-1"}]}
        },
        Page.info(connection, page_id)
      )
    end)

    assert_eventually(fn ->
      match?(
        [%{guid: "dialog-1", initializer: %{message: "Are you sure?"}}],
        Page.child_resources(connection, page_id, :dialog)
      )
    end)
  end

  test "await_event resolves matching page event" do
    %{connection: connection, page_id: page_id} = start_connection_with_page!()

    task =
      Task.async(fn ->
        Page.await_event(connection, page_id, &match?(%{method: :crash}, &1), 500)
      end)

    Connection.handle_playwright_msg(connection, %{guid: page_id, method: :crash, params: %{}})

    assert {:ok, %{method: :crash, guid: ^page_id}} = Task.await(task, 1_000)
  end

  test "await_child_resource resolves created dialog" do
    %{connection: connection, page_id: page_id} = start_connection_with_page!()

    task =
      Task.async(fn ->
        Page.await_child_resource(connection, page_id, :dialog, 500)
      end)

    Connection.handle_playwright_msg(connection, %{
      guid: page_id,
      method: :__create__,
      params: %{guid: "dialog-2", type: "Dialog", initializer: %{message: "Proceed?"}}
    })

    assert {:ok, %{guid: "dialog-2", type: :dialog, initializer: %{message: "Proceed?"}}} =
             Task.await(task, 1_000)
  end

  test "events returns oldest-first recent history" do
    %{connection: connection, page_id: page_id} = start_connection_with_page!()

    Connection.handle_playwright_msg(connection, %{guid: page_id, method: :console, params: %{text: "one"}})
    Connection.handle_playwright_msg(connection, %{guid: page_id, method: :console, params: %{text: "two"}})

    assert_eventually(fn ->
      match?(
        [
          %{method: :__create__},
          %{method: :console, params: %{text: "one"}},
          %{method: :console, params: %{text: "two"}}
        ],
        Page.events(connection, page_id, 10)
      )
    end)
  end

  defp start_connection_with_page! do
    connection = String.to_atom("page_resource_connection_#{System.unique_integer([:positive])}")
    scope = String.to_atom("page_resource_scope_#{System.unique_integer([:positive])}")
    frame_id = "frame-1"
    page_id = "page-1"

    {:ok, _} = :pg.start_link(scope)
    {:ok, _} = Registry.start_link(keys: :unique, name: Page.registry_name(connection))
    {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: Page.supervisor_name(connection))

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

    assert_eventually(fn ->
      case safe_initializer(connection, page_id) do
        {:ok, initializer} -> match?({:ok, _pid}, Page.ensure_started(connection, page_id, initializer))
        :error -> false
      end
    end)

    %{connection: connection, page_id: page_id, frame_id: frame_id}
  end

  defp safe_initializer(connection, guid) do
    {:ok, Connection.initializer!(connection, guid)}
  catch
    :exit, _reason -> :error
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
