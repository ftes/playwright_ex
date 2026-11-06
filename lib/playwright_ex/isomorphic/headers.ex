defmodule PlaywrightEx.Isomorphic.Headers do
  @upstream "packages/isomorphic/headers.ts"
  @moduledoc """
  Port of `#{@upstream}`. A `HeadersObject` is a map with string keys, a `HeadersArray` a list
  of `%{name: _, value: _}` maps.
  """

  def headers_object_to_array(headers, separator \\ nil, set_cookie_separator \\ nil) do
    set_cookie_separator = set_cookie_separator || separator

    for {name, values} <- headers, values != nil, name = to_string(name), reduce: [] do
      result ->
        if separator do
          sep = if String.downcase(name) == "set-cookie", do: set_cookie_separator, else: separator
          result ++ for(value <- String.split(values, sep), do: %{name: name, value: String.trim(value)})
        else
          result ++ [%{name: name, value: values}]
        end
    end
  end

  def headers_array_to_object(headers, lower_case) do
    Map.new(headers, fn %{name: name, value: value} ->
      {if(lower_case, do: String.downcase(name), else: name), value}
    end)
  end

  def split_set_cookie_header(headers) do
    index = Enum.find_index(headers, fn %{name: name} -> String.downcase(name) == "set-cookie" end)

    if index == nil do
      headers
    else
      header = Enum.at(headers, index)
      values = String.split(header.value, "\n")

      if length(values) == 1 do
        headers
      else
        result = Enum.map(values, &%{name: header.name, value: &1})
        Enum.take(headers, index) ++ result ++ Enum.drop(headers, index + 1)
      end
    end
  end
end
