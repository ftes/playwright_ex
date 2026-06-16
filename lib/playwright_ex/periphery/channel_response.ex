defmodule PlaywrightEx.ChannelResponse do
  @moduledoc false

  alias PlaywrightEx.Connection

  @spec unwrap(any(), (any() -> result)) :: {:ok, result} | {:error, any()} when result: any()
  def unwrap(%{error: error}, _), do: {:error, error}
  def unwrap(%{result: result}, fun) when is_function(fun, 1), do: {:ok, fun.(result)}
  def unwrap(other, fun) when is_function(fun, 1), do: {:ok, other}

  @doc """
  Unwraps a `Frame.expect` reply into `{:ok, matches?}`, applying `is_not`.

  Playwright 1.60 replied `%{result: %{matches: boolean}}`. 1.61 dropped that
  field and signals the outcome by success-vs-error: a non-match returns an
  error carrying `error_details`. Mirrors playwright-core's `Frame._expect`, so
  `matches?` (raw positive-condition result, `is_not` applied) stays identical
  across drivers; a genuine 1.60 error still propagates as `{:error, _}`.
  """
  @spec unwrap_expect(map(), boolean()) :: {:ok, boolean()} | {:error, any()}
  def unwrap_expect(%{result: %{matches: matches}}, _is_not) when is_boolean(matches), do: {:ok, matches}
  def unwrap_expect(%{error_details: _details}, is_not) when is_boolean(is_not), do: {:ok, is_not}
  def unwrap_expect(%{error: error}, _is_not), do: {:error, error}
  def unwrap_expect(reply, is_not) when is_map(reply) and is_boolean(is_not), do: {:ok, not is_not}

  @spec unwrap_create(any(), atom(), GenServer.name()) :: {:ok, any()} | {:error, any()}
  def unwrap_create(value, resource_name, connection) when is_atom(resource_name) do
    unwrap(value, fn result ->
      resource = Map.fetch!(result, resource_name)
      Map.merge(resource, Connection.initializer!(connection, resource.guid))
    end)
  end
end
