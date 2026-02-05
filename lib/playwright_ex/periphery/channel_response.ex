defmodule PlaywrightEx.ChannelResponse do
  @moduledoc false

  alias PlaywrightEx.Connection

  @spec unwrap(any(), (any() -> result)) :: {:ok, result} | {:error, any()} when result: any()
  def unwrap(%{error: error}, _), do: {:error, error}
  def unwrap(%{result: result}, fun) when is_function(fun, 1), do: {:ok, fun.(result)}
  def unwrap(other, fun) when is_function(fun, 1), do: {:ok, other}

  @spec unwrap_create(any(), atom(), GenServer.name()) :: {:ok, any()} | {:error, any()}
  def unwrap_create(value, resource_name, connection) when is_atom(resource_name) do
    unwrap(value, fn result ->
      resource = Map.fetch!(result, resource_name)
      Map.merge(resource, Connection.initializer!(connection, resource.guid))
    end)
  end
end
