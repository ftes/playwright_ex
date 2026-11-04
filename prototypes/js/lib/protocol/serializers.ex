# upstream: packages/protocol/src/serializers.ts
# JS has `undefined` and `null`; Elixir has `nil` (serialized as undefined) and `:null`.
defmodule PlaywrightJS.Protocol.Serializers do
  # upstream: serializers.ts:31
  def parse_serialized_value(value, handles) do
    inner_parse_serialized_value(value, handles, %{}, [])
  end

  # upstream: serializers.ts:35
  defp inner_parse_serialized_value(value, handles, refs, access_chain) do
    cond do
      value[:ref] != nil -> refs[value.ref]
      value[:n] != nil -> value.n
      value[:s] != nil -> value.s
      value[:b] != nil -> value.b
      value[:v] == "undefined" -> nil
      value[:v] == "null" -> :null
      value[:v] == "NaN" -> :nan
      value[:v] == "Infinity" -> :infinity
      value[:v] == "-Infinity" -> :neg_infinity
      value[:v] == "-0" -> -0.0
      value[:d] != nil -> elem(DateTime.from_iso8601(value.d), 1)
      value[:u] != nil -> URI.parse(value.u)
      value[:bi] != nil -> String.to_integer(value.bi)
      value[:e] != nil -> %RuntimeError{message: value.e.m}
      value[:r] != nil -> Regex.compile!(value.r.p, value.r.f)
      # typed arrays  -- not ported
      value[:a] != nil -> Enum.with_index(value.a, fn v, i -> inner_parse_serialized_value(v, handles, refs, access_chain ++ [i]) end)
      value[:o] != nil -> Map.new(value.o, fn %{k: k, v: v} -> {k, inner_parse_serialized_value(v, handles, refs, access_chain ++ [k])} end)
      value[:h] != nil -> if(handles == nil, do: raise("Unexpected handle"), else: Enum.at(handles, value.h))
      true -> raise "Attempting to deserialize unexpected value: #{inspect(value)}"
    end
  end

  # upstream: serializers.ts:110
  def serialize_value(value, handle_serializer) do
    inner_serialize_value(value, handle_serializer, %{lastId: 0, visited: %{}}, [])
  end

  # upstream: serializers.ts:118
  defp inner_serialize_value(value, handle_serializer, visitor_info, access_chain) do
    handle = handle_serializer.(value)

    if not Map.has_key?(handle, :fallThrough) do
      handle
    else
      value = handle.fallThrough

      cond do
        value == nil ->
          %{v: "undefined"}

        value == :null ->
          %{v: "null"}

        value == :nan ->
          %{v: "NaN"}

        value == :infinity ->
          %{v: "Infinity"}

        value == :neg_infinity ->
          %{v: "-Infinity"}

        is_boolean(value) ->
          %{b: value}

        is_number(value) ->
          %{n: value}

        is_binary(value) ->
          %{s: value}

        is_atom(value) ->
          %{s: Atom.to_string(value)}

        is_exception(value) ->
          %{e: %{n: inspect(value.__struct__), m: Exception.message(value), s: ""}}

        is_struct(value, DateTime) ->
          %{d: DateTime.to_iso8601(value)}

        is_struct(value, URI) ->
          %{u: URI.to_string(value)}

        is_struct(value, Regex) ->
          %{r: %{p: Regex.source(value), f: PlaywrightJS.Isomorphic.StringUtils.regex_flags(value)}}

        # typed arrays, cyclic refs  -- not ported (Elixir terms are acyclic)
        is_list(value) ->
          %{a: Enum.with_index(value, fn v, i -> inner_serialize_value(v, handle_serializer, visitor_info, access_chain ++ [i]) end), id: 0}

        is_map(value) ->
          %{
            o:
              Enum.map(value, fn {k, v} ->
                %{k: to_string(k), v: inner_serialize_value(v, handle_serializer, visitor_info, access_chain ++ [k])}
              end),
            id: 0
          }

        true ->
          raise "Attempting to serialize unexpected value: #{inspect(value)}"
      end
    end
  end
end
