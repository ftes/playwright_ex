defmodule PlaywrightEx.Serialization do
  @moduledoc false

  def camelize(:inner_html), do: "innerHTML"
  def camelize(:base_url), do: "baseURL"
  def camelize(:ignore_https_errors), do: "ignoreHTTPSErrors"
  def camelize(input), do: input |> to_string() |> camelize(:lower)
  def underscore(string), do: string |> Macro.underscore() |> String.to_atom()

  def deep_key_camelize(input), do: deep_key_transform(input, &camelize/1)
  def deep_key_underscore(input), do: deep_key_transform(input, &underscore/1)
  def regex_flags_for_protocol(opts), do: do_regex_flags_for_protocol(opts)

  @doc """
  Serializes an Elixir value to the Playwright protocol format.

  This is the inverse of `deserialize_arg/1`.
  """
  def serialize_arg(value), do: %{value: do_serialize_arg(value), handles: []}

  defp do_serialize_arg(nil), do: %{v: "undefined"}
  defp do_serialize_arg(true), do: %{b: true}
  defp do_serialize_arg(false), do: %{b: false}
  defp do_serialize_arg(n) when is_number(n), do: %{n: n}
  defp do_serialize_arg(s) when is_binary(s), do: %{s: s}
  defp do_serialize_arg(a) when is_atom(a), do: %{s: to_string(a)}
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

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def deserialize_arg(value) do
    case value do
      list when is_list(list) ->
        Enum.map(list, &deserialize_arg/1)

      %{a: list} ->
        Enum.map(list, &deserialize_arg/1)

      %{b: boolean} ->
        boolean

      %{n: number} ->
        number

      %{o: object} ->
        Map.new(object, fn item -> {item.k, deserialize_arg(item.v)} end)

      %{r: %{p: pattern, f: flags}} ->
        protocol_regex_to_elixir_regex(pattern, flags)

      %{s: string} ->
        string

      %{v: "null"} ->
        nil

      %{v: "undefined"} ->
        nil

      %{ref: _} ->
        :ref_not_resolved

      other ->
        raise ArgumentError,
              "PlaywrightEx.Serialization.deserialize_arg/1: unsupported serialized value shape " <>
                "(Playwright protocol drift?): #{inspect(other, limit: 20)}"
    end
  end

  defp deep_key_transform(input, fun) when is_function(fun, 1) do
    case input do
      list when is_list(list) ->
        Enum.map(list, &deep_key_transform(&1, fun))

      map when is_map(map) ->
        Map.new(map, fn
          {k, v} when is_map(v) ->
            {fun.(k), deep_key_transform(v, fun)}

          {k, list} when is_list(list) ->
            {fun.(k), Enum.map(list, fn v -> deep_key_transform(v, fun) end)}

          {k, v} ->
            {fun.(k), v}
        end)

      other ->
        other
    end
  end

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
