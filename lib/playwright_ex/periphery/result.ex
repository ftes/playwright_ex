defmodule PlaywrightEx.Result do
  @moduledoc false

  def from_response(%{error: error}, _), do: {:error, error}
  def from_response(value, fun) when is_function(fun, 1), do: {:ok, fun.(value)}

  def map({:error, error}, _), do: {:error, error}
  def map({:ok, value}, fun) when is_function(fun, 1), do: {:ok, fun.(value)}
end
