defmodule PlaywrightEx.Isomorphic.UtilityScriptSerializers do
  @upstream "packages/isomorphic/utilityScriptSerializers.ts"
  @moduledoc """
  Port of `#{@upstream}`: the client side, `serializeAsCallArgument` (init script arguments
  with exposed functions). Elixir terms map to JS values as in `PlaywrightEx.Protocol.Serializers`.

  Deviations: Elixir terms are acyclic, so `ref` is never emitted; there are no typed arrays,
  `ArrayBuffer`s, `Map`s, `Set`s or DOM objects to serialize.
  """
  import Bitwise

  # Name prefix of the page bindings backing the functions passed to evaluate()
  # as arguments. Only functions carrying this prefix serialize as { fn },
  # arbitrary functions are dropped as before.
  def k_function_binding_prefix, do: "__pw_fn_"

  def k_binding_controller_property, do: "__playwright__binding__controller__"

  @max_safe_integer (1 <<< 53) - 1

  # isRegExp, isDate, isURL, isError  -- ported as is_exception/1 and is_struct/2 guards
  # isTypedArray, isArrayBuffer, isMap, isSet, typedArrayToBase64, base64ToTypedArray  -- not ported: no such Elixir terms
  # parseEvaluationResultValue  -- not ported: runs in the page only

  @doc "`handle_serializer` returns `%{h: index}`, `%{fn: name}` or `%{fallThrough: value}`."
  def serialize_as_call_argument(value, handle_serializer, _options \\ %{}) do
    # extendedSerialization  -- not ported: no Map/Set terms
    serialize(value, handle_serializer, %{lastId: 0}) |> elem(0)
  end

  # Window/Document/Node aliasing  -- not ported: no DOM objects in Elixir
  defp serialize(value, handle_serializer, visitor_info) do
    inner_serialize(value, handle_serializer, visitor_info)
  end

  defp inner_serialize(value, handle_serializer, visitor_info) do
    case handle_serializer.(value) do
      %{fallThrough: value} -> serialize_fall_through(value, handle_serializer, visitor_info)
      result -> {result, visitor_info}
    end
  end

  defp serialize_fall_through(value, handle_serializer, visitor_info) do
    cond do
      value == nil -> {%{v: "undefined"}, visitor_info}
      value == :null -> {%{v: "null"}, visitor_info}
      value == :nan -> {%{v: "NaN"}, visitor_info}
      value == :infinity -> {%{v: "Infinity"}, visitor_info}
      value == :neg_infinity -> {%{v: "-Infinity"}, visitor_info}
      is_float(value) and value === -0.0 -> {%{v: "-0"}, visitor_info}
      is_boolean(value) -> {value, visitor_info}
      is_integer(value) and abs(value) > @max_safe_integer -> {%{bi: Integer.to_string(value)}, visitor_info}
      is_number(value) -> {value, visitor_info}
      is_binary(value) -> {value, visitor_info}
      is_atom(value) -> {Atom.to_string(value), visitor_info}
      is_exception(value) -> {serialize_error(value), visitor_info}
      is_struct(value, DateTime) -> {%{d: to_json_date(value)}, visitor_info}
      is_struct(value, URI) -> {%{u: URI.to_string(value)}, visitor_info}
      is_struct(value, Regex) -> {%{r: %{p: Regex.source(value), f: regex_flags(value)}}, visitor_info}
      is_list(value) -> serialize_array(value, handle_serializer, visitor_info)
      is_map(value) -> serialize_object(value, handle_serializer, visitor_info)
      # Functions without a binding (and other terms) are dropped: `undefined`.
      true -> {%{v: "undefined"}, visitor_info}
    end
  end

  defp serialize_error(e) do
    {name, message, stack} =
      case e do
        %{name: name, stack: stack} when is_binary(name) -> {name, Exception.message(e), stack || ""}
        _ -> {inspect(e.__struct__), Exception.message(e), ""}
      end

    stack =
      if String.starts_with?(stack, name <> ": " <> message),
        # v8
        do: stack,
        else: "#{name}: #{message}\n#{stack}"

    %{e: %{n: name, m: message, s: stack}}
  end

  defp serialize_array(value, handle_serializer, visitor_info) do
    id = visitor_info.lastId + 1

    {a, visitor_info} =
      Enum.map_reduce(value, %{visitor_info | lastId: id}, &serialize(&1, handle_serializer, &2))

    {%{a: a, id: id}, visitor_info}
  end

  defp serialize_object(value, handle_serializer, visitor_info) do
    id = visitor_info.lastId + 1
    map = if is_struct(value), do: Map.from_struct(value), else: value

    {o, visitor_info} =
      Enum.map_reduce(map, %{visitor_info | lastId: id}, fn {name, item}, visitor_info ->
        {v, visitor_info} = serialize(item, handle_serializer, visitor_info)
        {%{k: to_string(name), v: v}, visitor_info}
      end)

    {%{o: o, id: id}, visitor_info}
  end

  # Date.prototype.toJSON: millisecond precision, UTC.
  defp to_json_date(value),
    do: value |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp regex_flags(regex), do: PlaywrightEx.Protocol.Serializers.regex_flags(regex)
end
