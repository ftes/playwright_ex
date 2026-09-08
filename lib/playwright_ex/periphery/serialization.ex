defmodule PlaywrightEx.Serialization do
  @moduledoc false

  @max_safe_integer 9_007_199_254_740_991

  def camelize(:inner_html), do: "innerHTML"
  def camelize(:base_url), do: "baseURL"
  def camelize(:bypass_csp), do: "bypassCSP"
  def camelize(:extra_http_headers), do: "extraHTTPHeaders"
  def camelize(:handle_sighup), do: "handleSIGHUP"
  def camelize(:handle_sigint), do: "handleSIGINT"
  def camelize(:handle_sigterm), do: "handleSIGTERM"
  def camelize(:ignore_https_errors), do: "ignoreHTTPSErrors"
  def camelize(:indexed_db), do: "indexedDB"
  def camelize(:aria_snapshot_json), do: "ariaSnapshotJSON"
  def camelize(input) when is_binary(input), do: input
  def camelize(input), do: input |> to_string() |> camelize(:lower)

  def underscore(input) when is_atom(input), do: input

  def underscore(string) when is_binary(string) do
    underscored = Macro.underscore(string)

    try do
      String.to_existing_atom(underscored)
    rescue
      ArgumentError -> underscored
    end
  end

  def deep_key_camelize(input), do: deep_key_transform(input, &camelize/1, :to_wire)
  def deep_key_underscore(input), do: deep_key_transform(input, &underscore/1, :from_wire)
  def regex_flags_for_protocol(opts), do: do_regex_flags_for_protocol(opts)

  @doc """
  Serializes an Elixir value to the Playwright protocol format.

  This is the inverse of `deserialize_arg/1`.
  """
  def serialize_arg(value), do: %{value: do_serialize_arg(value), handles: []}

  defp do_serialize_arg(nil), do: %{v: "undefined"}
  defp do_serialize_arg(true), do: %{b: true}
  defp do_serialize_arg(false), do: %{b: false}
  defp do_serialize_arg(:nan), do: %{v: "NaN"}
  defp do_serialize_arg(:infinity), do: %{v: "Infinity"}
  defp do_serialize_arg(:negative_infinity), do: %{v: "-Infinity"}
  defp do_serialize_arg(:negative_zero), do: %{v: "-0"}
  defp do_serialize_arg({:handle, index}) when is_integer(index), do: %{h: index}
  defp do_serialize_arg({:function, name}) when is_binary(name), do: %{fn: name}
  defp do_serialize_arg({:reference, id}) when is_integer(id), do: %{ref: id}
  defp do_serialize_arg({:circular_reference, id}) when is_integer(id), do: %{ref: id}

  defp do_serialize_arg(%{type: type, data: data})
       when type in [
              :int8,
              :uint8,
              :uint8_clamped,
              :int16,
              :uint16,
              :int32,
              :uint32,
              :float32,
              :float64,
              :bigint64,
              :biguint64
            ] and is_binary(data) do
    %{ta: %{k: typed_array_protocol_kind(type), b: Base.encode64(data)}}
  end

  defp do_serialize_arg(n) when is_integer(n) and (n > @max_safe_integer or n < -@max_safe_integer),
    do: %{bi: to_string(n)}

  defp do_serialize_arg(n) when is_number(n), do: %{n: n}
  defp do_serialize_arg(s) when is_binary(s), do: %{s: s}
  defp do_serialize_arg(a) when is_atom(a), do: %{s: to_string(a)}
  defp do_serialize_arg(%DateTime{} = value), do: %{d: DateTime.to_iso8601(value)}

  defp do_serialize_arg(%NaiveDateTime{} = value) do
    %{d: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()}
  end

  defp do_serialize_arg(%URI{} = value), do: %{u: URI.to_string(value)}
  defp do_serialize_arg(%Regex{source: source, opts: opts}), do: %{r: %{p: source, f: do_regex_flags_for_protocol(opts)}}

  defp do_serialize_arg(list) when is_list(list) do
    %{a: Enum.map(list, &do_serialize_arg/1)}
  end

  defp do_serialize_arg(map) when is_map(map) do
    %{
      o:
        Enum.map(map, fn {k, v} ->
          %{k: to_string(k), v: do_serialize_arg(v)}
        end)
    }
  end

  def deserialize_arg(value) do
    ids = collect_serialized_ids(value, %{})
    deserialize_arg(value, ids, %{})
  end

  defp deserialize_arg(list, ids, resolving) when is_list(list) do
    Enum.map(list, &deserialize_arg(&1, ids, resolving))
  end

  defp deserialize_arg(%{ref: id}, ids, resolving), do: deserialize_reference(id, ids, resolving)

  defp deserialize_arg(%{a: list} = node, ids, resolving) do
    resolving = put_resolving_id(resolving, node)
    Enum.map(list, &deserialize_arg(&1, ids, resolving))
  end

  defp deserialize_arg(%{b: boolean}, _ids, _resolving), do: boolean
  defp deserialize_arg(%{n: number}, _ids, _resolving), do: number

  defp deserialize_arg(%{o: object} = node, ids, resolving) do
    resolving = put_resolving_id(resolving, node)
    Map.new(object, fn item -> {item.k, deserialize_arg(item.v, ids, resolving)} end)
  end

  defp deserialize_arg(%{r: %{p: pattern, f: flags}}, _ids, _resolving) do
    protocol_regex_to_elixir_regex(pattern, flags)
  end

  defp deserialize_arg(%{s: string}, _ids, _resolving), do: string
  defp deserialize_arg(%{v: "null"}, _ids, _resolving), do: nil
  defp deserialize_arg(%{v: "undefined"}, _ids, _resolving), do: nil
  defp deserialize_arg(%{v: "NaN"}, _ids, _resolving), do: :nan
  defp deserialize_arg(%{v: "Infinity"}, _ids, _resolving), do: :infinity
  defp deserialize_arg(%{v: "-Infinity"}, _ids, _resolving), do: :negative_infinity
  defp deserialize_arg(%{v: "-0"}, _ids, _resolving), do: :negative_zero
  defp deserialize_arg(%{d: datetime}, _ids, _resolving), do: deserialize_datetime(datetime)
  defp deserialize_arg(%{u: url}, _ids, _resolving), do: URI.parse(url)
  defp deserialize_arg(%{bi: integer}, _ids, _resolving), do: String.to_integer(integer)

  defp deserialize_arg(%{ta: %{b: data, k: kind}}, _ids, _resolving) do
    %{type: typed_array_kind(kind), data: Base.decode64!(data)}
  end

  defp deserialize_arg(%{e: error}, _ids, _resolving), do: deserialize_javascript_error(error)
  defp deserialize_arg(%{h: index}, _ids, _resolving), do: {:handle, index}
  defp deserialize_arg(%{fn: name}, _ids, _resolving), do: {:function, name}

  defp deserialize_arg(other, _ids, _resolving) do
    raise ArgumentError,
          "PlaywrightEx.Serialization.deserialize_arg/1: unsupported serialized value shape " <>
            "(Playwright protocol drift?): #{inspect(other, limit: 20)}"
  end

  defp collect_serialized_ids(list, ids) when is_list(list) do
    Enum.reduce(list, ids, &collect_serialized_ids/2)
  end

  defp collect_serialized_ids(%{} = value, ids) do
    ids = if is_integer(value[:id]), do: Map.put(ids, value.id, value), else: ids
    Enum.reduce(Map.values(value), ids, &collect_serialized_ids/2)
  end

  defp collect_serialized_ids(_value, ids), do: ids

  defp deserialize_reference(id, ids, resolving) do
    cond do
      Map.has_key?(resolving, id) -> {:circular_reference, id}
      value = ids[id] -> deserialize_arg(value, ids, Map.put(resolving, id, true))
      true -> {:reference, id}
    end
  end

  defp put_resolving_id(resolving, %{id: id}) when is_integer(id), do: Map.put(resolving, id, true)
  defp put_resolving_id(resolving, _value), do: resolving

  defp deserialize_datetime(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, value, _offset} -> value
      {:error, _reason} -> datetime
    end
  end

  defp deserialize_javascript_error(error) do
    maybe_put(%{name: error.n, message: error.m}, :stack, error[:s])
  end

  defp typed_array_kind("i8"), do: :int8
  defp typed_array_kind("ui8"), do: :uint8
  defp typed_array_kind("ui8c"), do: :uint8_clamped
  defp typed_array_kind("i16"), do: :int16
  defp typed_array_kind("ui16"), do: :uint16
  defp typed_array_kind("i32"), do: :int32
  defp typed_array_kind("ui32"), do: :uint32
  defp typed_array_kind("f32"), do: :float32
  defp typed_array_kind("f64"), do: :float64
  defp typed_array_kind("bi64"), do: :bigint64
  defp typed_array_kind("bui64"), do: :biguint64

  defp typed_array_protocol_kind(:int8), do: "i8"
  defp typed_array_protocol_kind(:uint8), do: "ui8"
  defp typed_array_protocol_kind(:uint8_clamped), do: "ui8c"
  defp typed_array_protocol_kind(:int16), do: "i16"
  defp typed_array_protocol_kind(:uint16), do: "ui16"
  defp typed_array_protocol_kind(:int32), do: "i32"
  defp typed_array_protocol_kind(:uint32), do: "ui32"
  defp typed_array_protocol_kind(:float32), do: "f32"
  defp typed_array_protocol_kind(:float64), do: "f64"
  defp typed_array_protocol_kind(:bigint64), do: "bi64"
  defp typed_array_protocol_kind(:biguint64), do: "bui64"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  def serialized_error_message(%{error: %{message: message}}) when is_binary(message), do: message

  def serialized_error_message(%{value: value}) do
    case deserialize_arg(value) do
      message when is_binary(message) -> message
      %{message: message} when is_binary(message) -> message
      other -> inspect(other)
    end
  end

  def serialized_error_message(error), do: inspect(error)

  defp deep_key_transform(list, fun, direction) when is_list(list) do
    Enum.map(list, &deep_key_transform(&1, fun, direction))
  end

  defp deep_key_transform(map, fun, direction) when is_map(map) do
    indexed_db_record? = indexed_db_record?(map)
    Map.new(map, &transform_key_value(&1, fun, direction, indexed_db_record?))
  end

  defp deep_key_transform(other, _fun, _direction), do: other

  defp transform_key_value({key, value}, fun, direction, indexed_db_record?) do
    transformed_key = fun.(key)

    transformed_value =
      if opaque_json_field?(direction, transformed_key, indexed_db_record?) do
        value
      else
        deep_key_transform(value, fun, direction)
      end

    {transformed_key, transformed_value}
  end

  defp indexed_db_record?(map) do
    Enum.any?([:key_encoded, :value_encoded, "keyEncoded", "valueEncoded"], &Map.has_key?(map, &1))
  end

  defp opaque_json_field?(:to_wire, key, _indexed_db_record?) when key in ["expressionArg", "firefoxUserPrefs"], do: true
  defp opaque_json_field?(:from_wire, :snapshot, _indexed_db_record?), do: true
  defp opaque_json_field?(_direction, key, true) when key in [:key, :value, "key", "value"], do: true
  defp opaque_json_field?(_direction, _key, _indexed_db_record?), do: false

  defp camelize("", :lower), do: ""
  defp camelize(<<?_, t::binary>>, :lower), do: camelize(t, :lower)

  defp camelize(<<h, _t::binary>> = value, :lower) do
    <<_first, rest::binary>> = Macro.camelize(value)
    <<to_lower_char(h)>> <> rest
  end

  defp to_lower_char(char) when char in ?A..?Z, do: char + 32
  defp to_lower_char(char), do: char

  defp do_regex_flags_for_protocol(opts) when is_binary(opts), do: canonicalize_protocol_regex_flags(opts)

  defp do_regex_flags_for_protocol(opts) when is_list(opts) do
    opts
    |> Enum.reduce("", fn opt, acc -> acc <> regex_flag_for_elixir_opt(opt) end)
    |> canonicalize_protocol_regex_flags()
  end

  defp regex_flag_for_elixir_opt(:caseless), do: "i"
  defp regex_flag_for_elixir_opt(:multiline), do: "m"
  defp regex_flag_for_elixir_opt(:dotall), do: "s"
  defp regex_flag_for_elixir_opt(:unicode), do: "u"
  defp regex_flag_for_elixir_opt(:ucp), do: "u"
  defp regex_flag_for_elixir_opt(_opt), do: ""

  defp protocol_regex_to_elixir_regex(pattern, flags) when is_binary(pattern) and is_binary(flags) do
    supported_flags = keep_supported_elixir_regex_flags(flags)
    Regex.compile!(pattern, supported_flags)
  end

  defp keep_supported_elixir_regex_flags(flags), do: canonicalize_protocol_regex_flags(flags)

  defp canonicalize_protocol_regex_flags(flags) do
    Enum.reduce(["i", "m", "s", "u"], "", fn flag, acc ->
      if String.contains?(flags, flag), do: acc <> flag, else: acc
    end)
  end
end
