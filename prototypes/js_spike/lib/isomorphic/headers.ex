# upstream: packages/isomorphic/headers.ts (subset)
defmodule PlaywrightJS.Isomorphic.Headers do
  # upstream: headers.ts:20 (separator variants not ported)
  def headers_object_to_array(headers) do
    for {name, value} <- headers, value != nil, do: %{name: to_string(name), value: to_string(value)}
  end
end
