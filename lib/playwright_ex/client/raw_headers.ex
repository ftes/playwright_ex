defmodule PlaywrightEx.Client.RawHeaders do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc """
  Port of `RawHeaders` in `#{@upstream}`: a plain struct, it has no mutable state.

  `_headersMap` (a `MultiMap`) is an insertion-ordered list of `{lower_name, values}`.
  """
  defstruct _headersArray: [], _headersMap: []

  def _from_headers_object_lossy(headers) do
    headers_array =
      for {name, value} <- headers, value != nil, do: %{name: to_string(name), value: value}

    new(headers_array)
  end

  def new(headers) do
    headers_map =
      Enum.reduce(headers, [], fn header, map ->
        key = String.downcase(header.name)

        if List.keymember?(map, key, 0),
          do: List.keyreplace(map, key, 0, {key, elem(List.keyfind(map, key, 0), 1) ++ [header.value]}),
          else: map ++ [{key, [header.value]}]
      end)

    %__MODULE__{_headersArray: headers, _headersMap: headers_map}
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
    case List.keyfind(this._headersMap, String.downcase(name), 0) do
      {_, values} -> values
      nil -> []
    end
  end

  def headers(this) do
    Map.new(this._headersMap, fn {name, _} -> {name, get(this, name)} end)
  end

  def headers_array(this) do
    this._headersArray
  end
end
