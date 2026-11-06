defmodule PlaywrightEx.Client.ClientHelper do
  @upstream "packages/playwright-core/src/client/clientHelper.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  Scripts are JS source strings (architecture: Value mapping). A JS function script is a string
  with an `arg` (`"(arg) => ..."`), or any string when functions are exposed;
  `JSON.stringify(arg)` is `json_stringify/1`, `JSON.parse(text)` `json_parse/1`.
  """
  alias PlaywrightEx.Isomorphic.UtilityScriptSerializers
  alias PlaywrightEx.Protocol.Validator
  alias PlaywrightEx.Runtime.Promise

  # envObjectToArray  -- not ported: inlined in BrowserType.launch

  def evaluation_script(fun, arg \\ nil, add_source_url \\ true) do
    cond do
      # typeof fun === 'function'
      is_binary(fun) and arg != nil ->
        source = fun
        arg_string = json_stringify(arg)
        "(#{source})(#{arg_string})"

      arg != nil ->
        raise "Cannot evaluate a string with arguments"

      is_binary(fun) ->
        fun

      fun[:content] != nil ->
        fun.content

      fun[:path] != nil ->
        source = File.read!(fun.path)
        if add_source_url, do: add_source_url_to_script(source, fun.path), else: source

      true ->
        raise "Either path or content property must be present"
    end
  end

  # `expose` returns a promise (a JS async function).
  def init_script_source_with_exposed_functions(fun, arg, expose) do
    # `exposePromises.push(...)` from the serializer callback: an accumulator in the process dictionary.
    expose_promises = make_ref()
    Process.put(expose_promises, [])

    serialized =
      UtilityScriptSerializers.serialize_as_call_argument(arg, fn value ->
        if is_function(value) do
          name = UtilityScriptSerializers.k_function_binding_prefix() <> create_guid()
          Process.put(expose_promises, Process.get(expose_promises) ++ [expose.(name, value)])
          %{fn: name}
        else
          %{fallThrough: value}
        end
      end)

    Promise.await(Promise.all(Process.delete(expose_promises)))
    # Bindings backing the functions are registered through their own init scripts
    # that are guaranteed to run first, so the controller is available here.
    "(#{fun})(globalThis['#{UtilityScriptSerializers.k_binding_controller_property()}'].parseInitScriptArg(#{JSON.encode!(serialized)}))"
  end

  def add_source_url_to_script(source, path) do
    "#{source}\n//# sourceURL=#{String.replace(path, "\n", "")}"
  end

  # utils/crypto.ts createGuid()
  @doc false
  def create_guid, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  # Elixir only: `JSON.stringify(arg)` of an Elixir term (`:null` is `null`, `nil` and functions
  # are `undefined`: dropped from objects, `null` in arrays).
  @doc false
  def json_stringify(arg) do
    if is_function(arg), do: "undefined", else: JSON.encode!(to_json(arg))
  end

  defp to_json(:null), do: nil
  defp to_json(value) when is_boolean(value) or is_nil(value), do: value
  defp to_json(value) when is_atom(value), do: Atom.to_string(value)
  defp to_json(value) when is_list(value), do: Enum.map(value, &if(is_function(&1), do: nil, else: to_json(&1)))
  # `toISOString()`: UTC, always milliseconds.
  defp to_json(%DateTime{} = value) do
    value = DateTime.shift_zone!(value, "Etc/UTC")
    {microsecond, _precision} = value.microsecond
    DateTime.to_iso8601(%{value | microsecond: {div(microsecond, 1000) * 1000, 3}})
  end

  defp to_json(value) when is_map(value) and not is_struct(value) do
    for {k, v} <- value, v != nil and not is_function(v), into: %{}, do: {k, to_json(v)}
  end

  defp to_json(value), do: value

  # Elixir only: `JSON.stringify(value, undefined, indent)` of a protocol value (`nil` is `null`).
  # `scheme` (a protocol type, `"BrowserContextStorageStateResult"`) gives the keys JS's order,
  # the validator's (decoded maps lose it); keys it does not name follow.
  @doc false
  def json_stringify_indented(value, indent, scheme \\ nil) do
    value = if scheme, do: _in_scheme_order(value, {:type, scheme}), else: value
    IO.iodata_to_binary(_stringify(value, String.duplicate(" ", indent), "\n"))
  end

  defp _stringify({:ordered, pairs}, gap, sep), do: _stringify_object(pairs, gap, sep)

  defp _stringify(value, gap, sep) when is_map(value) and not is_struct(value),
    do: _stringify_object(Map.to_list(value), gap, sep)

  defp _stringify([], _gap, _sep), do: "[]"

  defp _stringify(value, gap, sep) when is_list(value) do
    inner = sep <> gap
    ["[", inner, Enum.map_intersperse(value, [",", inner], &_stringify(&1, gap, inner)), sep, "]"]
  end

  defp _stringify(nil, _gap, _sep), do: "null"
  defp _stringify(value, _gap, _sep), do: :json.encode(value)

  defp _stringify_object([], _gap, _sep), do: "{}"

  defp _stringify_object(pairs, gap, sep) do
    inner = sep <> gap

    entries =
      Enum.map_intersperse(pairs, [",", inner], fn {k, v} ->
        [:json.encode(to_string(k)), ": ", _stringify(v, gap, inner)]
      end)

    ["{", inner, entries, sep, "}"]
  end

  defp _in_scheme_order(value, {:type, name}), do: _in_scheme_order(value, Validator.scheme(name))
  defp _in_scheme_order(value, {:optional, scheme}), do: _in_scheme_order(value, scheme)
  defp _in_scheme_order(value, {:array, scheme}) when is_list(value), do: Enum.map(value, &_in_scheme_order(&1, scheme))

  defp _in_scheme_order(value, {:object, fields}) when is_map(value) and not is_struct(value) do
    known = for {key, scheme} <- fields, Map.has_key?(value, key), do: {key, _in_scheme_order(value[key], scheme)}
    {:ordered, known ++ Enum.sort(Map.to_list(Map.drop(value, Keyword.keys(fields))))}
  end

  defp _in_scheme_order(value, _scheme), do: value

  # Elixir only: `JSON.parse(text)`, JS `null` is `:null`. Raises `JSON.DecodeError` (a JS SyntaxError).
  @doc false
  def json_parse(text) do
    case JSON.decode(text, nil, null: :null) do
      {value, nil, ""} -> value
      _ -> JSON.decode!(text)
    end
  end

  # Elixir only: `String(number)`, JS Number::toString: the shortest round-trip digits, in
  # exponent form when the decimal exponent is >= 21 or <= -7 (`1e+21`, `1e-7`). Integers are JS
  # numbers too: beyond 2^53 they are rounded to a double first.
  @doc false
  def number_to_string(number) when is_integer(number) and abs(number) <= 9_007_199_254_740_992,
    do: Integer.to_string(number)

  def number_to_string(number) when is_integer(number), do: number_to_string(number * 1.0)
  def number_to_string(:nan), do: "NaN"
  def number_to_string(:infinity), do: "Infinity"
  def number_to_string(:neg_infinity), do: "-Infinity"
  def number_to_string(number) when number == 0, do: "0"
  def number_to_string(number) when number < 0, do: "-" <> number_to_string(-number)

  def number_to_string(number) when is_float(number) do
    # Erlang's `:short` is the shortest round-trip form, `123.456` or `1.23e22`.
    [int, frac, exp] =
      case String.split(:erlang.float_to_binary(number, [:short]), ["e", "."]) do
        [int, frac] -> [int, frac, "0"]
        parts -> parts
      end

    # digits is s, n the decimal point's position (the value is 0.s * 10^n).
    digits = int <> frac
    n = byte_size(int) + String.to_integer(exp)
    trimmed = String.trim_leading(digits, "0")
    n = n - (byte_size(digits) - byte_size(trimmed))
    digits = String.trim_trailing(trimmed, "0")
    k = byte_size(digits)

    cond do
      k <= n and n <= 21 -> digits <> String.duplicate("0", n - k)
      0 < n and n <= 21 -> binary_part(digits, 0, n) <> "." <> binary_part(digits, n, k - n)
      -6 < n and n <= 0 -> "0." <> String.duplicate("0", -n) <> digits
      true -> exponent_form(digits, n - 1)
    end
  end

  defp exponent_form(digits, e) do
    sign = if e < 0, do: "-", else: "+"
    {first, rest} = String.split_at(digits, 1)
    if(rest == "", do: first, else: first <> "." <> rest) <> "e" <> sign <> Integer.to_string(abs(e))
  end

  # Elixir only: JS truthiness (`!!value`, the left side of `||`).
  @doc false
  def truthy(value), do: value not in [nil, false, :null, "", 0, +0.0, -0.0]

  # Elixir only: JS calls a function with any number of arguments. Missing ones are `undefined`
  # (`nil`), extra ones are dropped, as for a JS function with fewer parameters.
  @doc false
  def call_function(fun, args) do
    {:arity, arity} = Function.info(fun, :arity)
    args = Enum.take(args ++ List.duplicate(nil, max(arity - length(args), 0)), arity)
    apply(fun, args)
  end
end
