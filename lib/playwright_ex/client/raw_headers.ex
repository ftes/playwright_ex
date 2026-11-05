defmodule PlaywrightEx.Client.RawHeaders do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc """
  Port of `RawHeaders` in `#{@upstream}`: a plain struct, it has no mutable state.

  `_headersMap` (a `MultiMap`) is a map of lower-case name to values (in insertion order).
  """
  defstruct _headersArray: [], _headersMap: %{}

  def _from_headers_object_lossy(headers) do
    headers_array =
      for {name, value} <- headers, value != nil, do: %{name: to_string(name), value: value}

    new(headers_array)
  end

  def new(headers) do
    %__MODULE__{
      _headersArray: headers,
      _headersMap: Enum.group_by(headers, &String.downcase(&1.name), & &1.value)
    }
  end

  def get(this, name) do
    values = get_all(this, name)

    if !values or values == [] do
      nil
    else
      Enum.join(values, if(String.downcase(name) == "set-cookie", do: "\n", else: ", "))
    end
  end

  def get_all(this, name) do
    Map.get(this._headersMap, String.downcase(name), [])
  end

  def headers(this) do
    Map.new(this._headersMap, fn {name, _} -> {name, get(this, name)} end)
  end

  def headers_array(this) do
    this._headersArray
  end
end
