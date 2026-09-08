defmodule PlaywrightEx.ChannelResponse do
  @moduledoc false

  alias PlaywrightEx.Connection

  @spec unwrap(any(), (any() -> result)) :: {:ok, result} | {:error, any()} when result: any()
  def unwrap(%{error: %{} = error, error_details: details} = response, _) do
    {:error, {maybe_attach_log(error, response), details}}
  end

  def unwrap(%{error: error} = response, _), do: {:error, maybe_attach_log(error, response)}
  def unwrap(%{result: result}, fun) when is_function(fun, 1), do: {:ok, fun.(result)}
  def unwrap(%{id: _id}, fun) when is_function(fun, 1), do: {:ok, fun.(%{})}
  def unwrap(other, fun) when is_function(fun, 1), do: {:ok, other}

  @spec unwrap_create(any(), atom(), GenServer.name()) :: {:ok, any()} | {:error, any()}
  def unwrap_create(value, resource_name, connection) when is_atom(resource_name) do
    unwrap(value, fn result ->
      resource = Map.fetch!(result, resource_name)
      Map.merge(resource, Connection.initializer!(connection, resource.guid))
    end)
  end

  defp maybe_attach_log(%{} = error, %{log: log}) when is_list(log) and log != [], do: Map.put(error, :log, log)
  defp maybe_attach_log(error, _response), do: error
end
