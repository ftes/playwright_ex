defmodule PlaywrightEx.Resource do
  @moduledoc false

  alias PlaywrightEx.Resource.Frame
  alias PlaywrightEx.Resource.Page

  @type resource_module :: module()

  @spec modules() :: [resource_module()]
  def modules do
    [Page, Frame]
  end

  @spec children(atom()) :: [Supervisor.child_spec()]
  def children(connection) do
    Enum.flat_map(modules(), fn module ->
      [
        {Registry, keys: :unique, name: module.registry_name(connection)},
        {DynamicSupervisor, strategy: :one_for_one, name: module.supervisor_name(connection)}
      ]
    end)
  end

  @spec ensure_started(resource_module(), atom(), PlaywrightEx.guid(), map() | nil, map()) ::
          {:ok, pid()} | {:error, map()}
  def ensure_started(module, connection, resource_id, initializer \\ nil, extra_opts \\ %{}) do
    case lookup(module, connection, resource_id) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        start_child(module, connection, resource_id, initializer, extra_opts)
    end
  end

  @spec maybe_stop(resource_module(), atom(), PlaywrightEx.guid()) :: :ok
  def maybe_stop(module, connection, resource_id) do
    case lookup(module, connection, resource_id) do
      {:ok, pid} -> Process.exit(pid, :normal)
      :not_found -> :ok
    end

    :ok
  end

  @spec info(resource_module(), atom(), PlaywrightEx.guid()) :: map()
  def info(module, connection, resource_id) do
    call(module, connection, resource_id, :info)
  end

  @spec events(resource_module(), atom(), PlaywrightEx.guid(), pos_integer()) :: [map()]
  def events(module, connection, resource_id, limit) do
    call(module, connection, resource_id, {:events, limit})
  end

  @spec child_resources(resource_module(), atom(), PlaywrightEx.guid(), atom() | :all) :: map() | [map()]
  def child_resources(module, connection, resource_id, type) do
    call(module, connection, resource_id, {:child_resources, type})
  end

  @spec await(resource_module(), atom(), PlaywrightEx.guid(), term(), timeout()) :: any()
  def await(module, connection, resource_id, request, timeout) do
    with {:ok, pid} <- ensure_started(module, connection, resource_id) do
      module.call_resource(pid, request, timeout)
    end
  end

  @spec registry_name(resource_module(), atom()) :: atom()
  def registry_name(module, connection) do
    Module.concat(connection, "#{resource_name(module)}Registry")
  end

  @spec supervisor_name(resource_module(), atom()) :: atom()
  def supervisor_name(module, connection) do
    Module.concat(connection, "#{resource_name(module)}Supervisor")
  end

  @spec lookup(resource_module(), atom(), PlaywrightEx.guid()) :: {:ok, pid()} | :not_found
  def lookup(module, connection, resource_id) do
    registry = registry_name(module, connection)

    case Registry.lookup(registry, resource_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  defp call(module, connection, resource_id, request) do
    with {:ok, pid} <- ensure_started(module, connection, resource_id) do
      GenServer.call(pid, request)
    end
  end

  defp start_child(module, connection, resource_id, initializer, extra_opts) do
    child_opts =
      %{connection: connection, resource_id: resource_id}
      |> maybe_put_initializer(initializer)
      |> Map.merge(Map.take(extra_opts, [:pg_scope]))

    child_spec = {module, child_opts}

    case DynamicSupervisor.start_child(supervisor_name(module, connection), child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, %{message: "Failed to start #{resource_label(module)} resource: #{inspect(reason)}"}}
    end
  catch
    :exit, reason ->
      {:error, %{message: "Failed to start #{resource_label(module)} resource: #{Exception.format_exit(reason)}"}}
  end

  defp maybe_put_initializer(opts, initializer) when is_map(initializer), do: Map.put(opts, :initializer, initializer)
  defp maybe_put_initializer(opts, _initializer), do: opts

  defp resource_label(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp resource_name(module) do
    module
    |> Module.split()
    |> Enum.drop_while(&(&1 != "Resource"))
    |> Enum.join()
  end
end
