defmodule Playwright.Impl.Serialization do
  # upstream: Serialization.java:43
  # `gson().toJsonTree(options)` -> to_json_tree/1: struct -> wire map (nil fields dropped, field names mapped to
  # the protocol's camelCase names, enums (atoms) lower-cased, handles/locators -> protocol refs).
  alias Playwright.Impl.{LocatorImpl, Utils}
  alias Playwright.PlaywrightException

  # upstream: Serialization.java:77 (gson().toJsonTree)
  def to_json_tree(nil), do: %{}
  def to_json_tree(%LocatorImpl{} = locator), do: LocatorImpl.to_protocol(locator)
  def to_json_tree(%{guid: guid, connection: _}), do: %{"guid" => guid}
  def to_json_tree(%Regex{} = regex), do: Regex.source(regex)

  def to_json_tree(%module{} = struct) do
    names = if function_exported?(module, :__json_names__, 0), do: module.__json_names__(), else: %{}

    for {key, value} <- Map.from_struct(struct), value != nil, into: %{} do
      {Map.get_lazy(names, key, fn -> camelize(key) end), to_json_tree(value)}
    end
  end

  def to_json_tree(list) when is_list(list), do: Enum.map(list, &to_json_tree/1)
  def to_json_tree(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), to_json_tree(v)} end)
  def to_json_tree(value) when is_boolean(value) or is_nil(value), do: value
  def to_json_tree(value) when is_atom(value), do: value |> Atom.to_string() |> String.downcase()
  def to_json_tree(value), do: value

  # gson().fromJson(json, Class) for flat DTOs.
  def from_json(nil, _module), do: nil

  def from_json(json, module) do
    fields = module.__struct__() |> Map.from_struct() |> Map.keys()
    struct(module, for(field <- fields, Map.has_key?(json, camelize(field)), do: {field, json[camelize(field)]}))
  end

  defp camelize(key) do
    [first | rest] = key |> Atom.to_string() |> String.split("_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  defmodule ValueSerializer do
    # upstream: Serialization.java:100
    # Java mutates `lastId`/`handles` while recursing; here they are threaded as an accumulator.
    alias Playwright.Impl.Protocol.SerializedArgument

    # upstream: Serialization.java:124
    def new(value) do
      {serialized_value, state} = serialize_value(value, %{last_id: 0, handles: []})
      %{serialized_value: serialized_value, handles: state.handles}
    end

    # upstream: Serialization.java:128
    def to_serialized_argument(this) do
      %SerializedArgument{value: this.serialized_value, handles: Enum.map(this.handles, &%{"guid" => &1.guid})}
    end

    # upstream: Serialization.java:141
    defp serialize_value(value, state) do
      cond do
        is_struct(value) and Map.has_key?(value, :guid) ->
          {%{"h" => length(state.handles)}, %{state | handles: state.handles ++ [value]}}

        value == nil ->
          {%{"v" => "undefined"}, state}

        is_float(value) ->
          {%{"n" => value}, state}

        is_boolean(value) ->
          {%{"b" => value}, state}

        is_integer(value) ->
          {%{"n" => value}, state}

        is_binary(value) ->
          {%{"s" => value}, state}

        is_struct(value, Regex) ->
          {%{"r" => %{"p" => Regex.source(value), "f" => Utils.to_js_regex_flags(value)}}, state}

        is_list(value) ->
          id = state.last_id + 1
          {list, state} = Enum.map_reduce(value, %{state | last_id: id}, &serialize_value/2)
          {%{"a" => list, "id" => id}, state}

        is_map(value) ->
          id = state.last_id + 1

          {list, state} =
            Enum.map_reduce(value, %{state | last_id: id}, fn {k, v}, state ->
              {serialized, state} = serialize_value(v, state)
              {%{"k" => to_string(k), "v" => serialized}, state}
            end)

          {%{"o" => list, "id" => id}, state}

        true ->
          raise PlaywrightException, message: "Unsupported type of argument: #{inspect(value)}"
      end
    end
  end

  # upstream: Serialization.java:229
  def serialize_argument(arg), do: ValueSerializer.to_serialized_argument(ValueSerializer.new(arg))

  # upstream: Serialization.java:233
  def deserialize(value), do: deserialize(value, %{})

  # upstream: Serialization.java:238 (subset: primitives, arrays, objects)
  defp deserialize(value, id_to_value) do
    cond do
      Map.has_key?(value, "ref") -> id_to_value[value["ref"]]
      Map.has_key?(value, "n") -> value["n"]
      Map.has_key?(value, "s") -> value["s"]
      Map.has_key?(value, "b") -> value["b"]
      Map.has_key?(value, "v") -> if value["v"] in ["undefined", "null"], do: nil, else: value["v"]
      Map.has_key?(value, "a") -> Enum.map(value["a"], &deserialize(&1, id_to_value))
      Map.has_key?(value, "o") -> Map.new(value["o"], &{&1["k"], deserialize(&1["v"], id_to_value)})
      true -> raise PlaywrightException, message: "Unexpected result from evaluation: #{inspect(value)}"
    end
  end

  # upstream: Serialization.java:339
  def to_json_array(files) when is_list(files) do
    for p <- files, do: Path.expand(p)
  end

  # upstream: Serialization.java:423
  def to_select_value_or_label(values) do
    for value <- values, do: %{"valueOrLabel" => value}
  end

  # upstream: Serialization.java:442
  def parse_string_list(array), do: Enum.map(array, &to_string/1)
end
