defmodule PlaywrightEx.Protocol.Serializers do
  @upstream "packages/protocol/src/serializers.ts"
  @moduledoc """
  Port of `#{@upstream}`. Values are `SerializedValue` maps with atom keys, as returned by
  the protocol validator.

  JS values map to Elixir terms as follows: `undefined` is `nil`, `null` is `:null`,
  `NaN`/`Infinity`/`-Infinity` are `:nan`/`:infinity`/`:neg_infinity`, `-0` is `-0.0`,
  `bigint` is an integer outside ±(2^53 - 1), `Date` is `DateTime`, `URL` is `URI`,
  `RegExp` serializes from `Regex` or `PlaywrightEx.RegExp` and parses to `PlaywrightEx.RegExp`, `Error` is `JSError` (or any exception, when
  serializing), objects are maps with string keys (atom keys and structs are accepted when
  serializing). Other atoms serialize as strings.

  Deviations: a JS regex parses to a `PlaywrightEx.RegExp` (lossless, as JS's RegExp); typed arrays parse to lists of numbers and are
  never produced; a function parses to `{:function, name}`; Elixir terms are acyclic, so
  serializing never emits `ref`, and parsing a reference to an enclosing (cyclic) value
  returns `:circular`.
  """
  import Bitwise

  defmodule JSError do
    @moduledoc "A JavaScript `Error` value (`{e: {n, m, s}}`), e.g. returned by `evaluate`."
    defexception name: "Error", message: "", stack: ""
  end

  @max_safe_integer (1 <<< 53) - 1

  # See https://nodejs.org/api/errors.html#errorcode.
  def system_error_code(error) do
    case error do
      %{code: code} when is_binary(code) -> code
      _ -> nil
    end
  end

  def system_error_message(error) do
    message = Exception.message(error)

    case system_error_code(error) do
      nil ->
        message

      code ->
        if !(code =~ ~r/^E[A-Z0-9]+$/) or String.contains?(message, code), do: message, else: "#{message} (#{code})"
    end
  end

  def parse_serialized_value(value, handles) do
    {result, _refs} = inner_parse_serialized_value(value, handles, %{}, [])
    result
  end

  defp inner_parse_serialized_value(value, handles, refs, access_chain) do
    case value do
      %{ref: ref} ->
        {Map.get(refs, ref, :circular), refs}

      %{n: n} ->
        {n, refs}

      %{s: s} ->
        {s, refs}

      %{b: b} ->
        {b, refs}

      %{v: v} when v in ~w(undefined null NaN Infinity -Infinity -0) ->
        {parse_special(v), refs}

      %{d: d} ->
        {d |> DateTime.from_iso8601() |> elem(1), refs}

      %{u: u} ->
        {URI.parse(u), refs}

      %{bi: bi} ->
        {String.to_integer(bi), refs}

      %{e: e} ->
        {%JSError{name: e[:n], message: e[:m], stack: e[:s]}, refs}

      %{r: r} ->
        {%PlaywrightEx.RegExp{source: r.p, flags: r.f}, refs}

      %{ta: ta} ->
        {parse_typed_array(ta.k, ta.b), refs}

      %{a: a} ->
        parse_array(a, value[:id], handles, refs, access_chain)

      %{o: o} ->
        parse_object(o, value[:id], handles, refs, access_chain)

      %{h: h} ->
        if(handles == nil, do: raise("Unexpected handle"), else: {Enum.at(handles, h), refs})

      %{fn: name} ->
        {{:function, name}, refs}

      _ ->
        raise "Attempting to deserialize unexpected value#{access_chain_to_display_string(access_chain)}: #{inspect(value)}"
    end
  end

  defp parse_special("undefined"), do: nil
  defp parse_special("null"), do: :null
  defp parse_special("NaN"), do: :nan
  defp parse_special("Infinity"), do: :infinity
  defp parse_special("-Infinity"), do: :neg_infinity
  defp parse_special("-0"), do: -0.0

  defp parse_array(items, id, handles, refs, access_chain) do
    {result, refs} =
      items
      |> Enum.with_index()
      |> Enum.map_reduce(refs, fn {item, i}, refs ->
        inner_parse_serialized_value(item, handles, refs, access_chain ++ [i])
      end)

    {result, Map.put(refs, id, result)}
  end

  defp parse_object(entries, id, handles, refs, access_chain) do
    {pairs, refs} =
      Enum.map_reduce(entries, refs, fn %{k: k, v: v}, refs ->
        {parsed, refs} = inner_parse_serialized_value(v, handles, refs, access_chain ++ [k])
        {{k, parsed}, refs}
      end)

    result = Map.new(pairs)
    {result, Map.put(refs, id, result)}
  end

  @typed_arrays %{
    "i8" => {:signed, 8},
    "ui8" => {:unsigned, 8},
    "ui8c" => {:unsigned, 8},
    "i16" => {:signed, 16},
    "ui16" => {:unsigned, 16},
    "i32" => {:signed, 32},
    "ui32" => {:unsigned, 32},
    "f32" => {:float, 32},
    "f64" => {:float, 64},
    "bi64" => {:signed, 64},
    "bui64" => {:unsigned, 64}
  }

  defp parse_typed_array(kind, binary) do
    case Map.fetch!(@typed_arrays, kind) do
      {:signed, size} -> for <<x::little-signed-size(^size) <- binary>>, do: x
      {:unsigned, size} -> for <<x::little-unsigned-size(^size) <- binary>>, do: x
      {:float, size} -> for <<x::little-float-size(^size) <- binary>>, do: x
    end
  end

  @doc "`handle_serializer` returns `%{h: index}`, `%{fn: name}` or `%{fallThrough: value}`."
  def serialize_value(value, handle_serializer) do
    {result, _visitor_info} = inner_serialize_value(value, handle_serializer, %{lastId: 0}, [])
    result
  end

  def serialize_plain_value(arg), do: serialize_value(arg, fn value -> %{fallThrough: value} end)

  defp inner_serialize_value(value, handle_serializer, visitor_info, access_chain) do
    case handle_serializer.(value) do
      %{fallThrough: value} -> serialize_fall_through(value, handle_serializer, visitor_info, access_chain)
      handle -> {handle, visitor_info}
    end
  end

  defp serialize_fall_through(value, handle_serializer, visitor_info, access_chain) do
    cond do
      value == nil ->
        {%{v: "undefined"}, visitor_info}

      value == :null ->
        {%{v: "null"}, visitor_info}

      value == :nan ->
        {%{v: "NaN"}, visitor_info}

      value == :infinity ->
        {%{v: "Infinity"}, visitor_info}

      value == :neg_infinity ->
        {%{v: "-Infinity"}, visitor_info}

      is_float(value) and value === -0.0 ->
        {%{v: "-0"}, visitor_info}

      is_boolean(value) ->
        {%{b: value}, visitor_info}

      is_integer(value) and abs(value) > @max_safe_integer ->
        {%{bi: Integer.to_string(value)}, visitor_info}

      is_number(value) ->
        {%{n: value}, visitor_info}

      is_binary(value) ->
        {%{s: value}, visitor_info}

      is_atom(value) ->
        {%{s: Atom.to_string(value)}, visitor_info}

      # isRegExp, isDate, isURL, isError  -- ported as is_exception/1 and is_struct/2 guards
      is_exception(value) ->
        {serialize_error(value), visitor_info}

      is_struct(value, DateTime) ->
        {%{d: to_json_date(value)}, visitor_info}

      is_struct(value, URI) ->
        {%{u: URI.to_string(value)}, visitor_info}

      PlaywrightEx.RegExp.reg_exp?(value) ->
        {p, f} = PlaywrightEx.RegExp.to_js(value)
        {%{r: %{p: p, f: f}}, visitor_info}

      is_list(value) ->
        serialize_array(value, handle_serializer, visitor_info, access_chain)

      is_map(value) ->
        serialize_object(value, handle_serializer, visitor_info, access_chain)

      true ->
        raise "Attempting to serialize unexpected value#{access_chain_to_display_string(access_chain)}: #{inspect(value)}"
    end
  end

  defp serialize_error(%JSError{} = e), do: %{e: %{n: e.name, m: e.message, s: e.stack || ""}}
  defp serialize_error(e), do: %{e: %{n: inspect(e.__struct__), m: Exception.message(e), s: ""}}

  # Date.prototype.toJSON: millisecond precision, UTC.
  defp to_json_date(value),
    do: value |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp serialize_array(value, handle_serializer, visitor_info, access_chain) do
    id = visitor_info.lastId + 1

    {a, visitor_info} =
      value
      |> Enum.with_index()
      |> Enum.map_reduce(%{visitor_info | lastId: id}, fn {item, i}, visitor_info ->
        inner_serialize_value(item, handle_serializer, visitor_info, access_chain ++ [i])
      end)

    {%{a: a, id: id}, visitor_info}
  end

  defp serialize_object(value, handle_serializer, visitor_info, access_chain) do
    id = visitor_info.lastId + 1
    map = if is_struct(value), do: Map.from_struct(value), else: value

    {o, visitor_info} =
      Enum.map_reduce(map, %{visitor_info | lastId: id}, fn {name, item}, visitor_info ->
        name = to_string(name)
        {v, visitor_info} = inner_serialize_value(item, handle_serializer, visitor_info, access_chain ++ [name])
        {%{k: name, v: v}, visitor_info}
      end)

    {%{o: o, id: id}, visitor_info}
  end

  defp access_chain_to_display_string(access_chain) do
    chain_string =
      access_chain
      |> Enum.with_index()
      |> Enum.map_join(fn
        {accessor, 0} when is_binary(accessor) -> accessor
        {accessor, _} when is_binary(accessor) -> ".#{accessor}"
        {accessor, _} -> "[#{accessor}]"
      end)

    if chain_string == "", do: "", else: ~s( at position "#{chain_string}")
  end
end
