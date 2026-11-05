defmodule PlaywrightEx.Client.ClientHelper do
  @upstream "packages/playwright-core/src/client/clientHelper.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  Scripts are JS source strings (PLAN: evaluate). A JS function script is a string with an
  `arg` (`"(arg) => ..."`), or any string when functions are exposed; `JSON.stringify(arg)` is
  `json_stringify/1`, `JSON.parse(text)` `json_parse/1`.
  """
  alias PlaywrightEx.Isomorphic.UtilityScriptSerializers
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
  defp to_json(%DateTime{} = value), do: value

  defp to_json(value) when is_map(value) and not is_struct(value) do
    for {k, v} <- value, v != nil and not is_function(v), into: %{}, do: {k, to_json(v)}
  end

  defp to_json(value), do: value

  # Elixir only: `JSON.stringify(value, undefined, indent)` of a protocol value (`nil` is `null`).
  @doc false
  def json_stringify_indented(value, indent),
    do: IO.iodata_to_binary(json_stringify_indented(value, String.duplicate(" ", indent), ""))

  defp json_stringify_indented(value, _gap, _indent) when value == %{}, do: "{}"
  defp json_stringify_indented([], _gap, _indent), do: "[]"

  defp json_stringify_indented(value, gap, indent) when is_map(value) and not is_struct(value) do
    inner = indent <> gap
    members = for {k, v} <- value, do: [inner, JSON.encode!(to_string(k)), ": ", json_stringify_indented(v, gap, inner)]
    ["{\n", Enum.intersperse(members, ",\n"), "\n", indent, "}"]
  end

  defp json_stringify_indented(value, gap, indent) when is_list(value) do
    inner = indent <> gap
    elements = for v <- value, do: [inner, json_stringify_indented(v, gap, inner)]
    ["[\n", Enum.intersperse(elements, ",\n"), "\n", indent, "]"]
  end

  defp json_stringify_indented(value, _gap, _indent), do: JSON.encode!(value)

  # Elixir only: `JSON.parse(text)`, JS `null` is `:null`. Raises `JSON.DecodeError` (a JS SyntaxError).
  @doc false
  def json_parse(text) do
    case JSON.decode(text, nil, null: :null) do
      {value, nil, ""} -> value
      _ -> JSON.decode!(text)
    end
  end

  # Elixir only: `String(number)`: integral floats have no fraction (`100.0` is `"100"`).
  @doc false
  def number_to_string(number) when is_integer(number), do: Integer.to_string(number)

  def number_to_string(number) when is_float(number) and number == trunc(number) and abs(number) < 1.0e21,
    do: Integer.to_string(trunc(number))

  def number_to_string(number) when is_float(number), do: Float.to_string(number)

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
