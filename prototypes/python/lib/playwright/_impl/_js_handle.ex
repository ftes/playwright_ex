# upstream: playwright/_impl/_js_handle.py (subset: serialization helpers)
defmodule Playwright.Impl.JSHandle.VisitorInfo do
  use Py

  # upstream: _js_handle.py:42
  def init do
    self = Py.new(__MODULE__)
    Py.set(self, :visited, %{})
    Py.set(self, :last_id, 0)
    self
  end

  # upstream: _js_handle.py:46
  def visit(self, obj) do
    false = Map.has_key?(self[:visited], obj)
    Py.set(self, :last_id, self[:last_id] + 1)
    Py.set(self, :visited, Map.put(self[:visited], obj, self[:last_id]))
    self[:last_id]
  end
end

defmodule Playwright.Impl.JSHandle do
  alias Playwright.Impl.JSHandle.VisitorInfo
  alias Playwright.Impl.Errors
  alias Playwright.Impl.StrUtils

  # upstream: _js_handle.py:134
  # `handles` is an out-parameter list in Python -> returned alongside the value.
  def serialize_value(value, handles, visitor_info \\ nil) do
    visitor_info = if visitor_info == nil, do: VisitorInfo.init(), else: visitor_info

    cond do
      # isinstance(value, JSHandle) (JSHandle objects not in prototype subset)
      value == nil ->
        {%{"v" => "null"}, handles}

      is_float(value) and value == 0.0 and is_negative_zero(value) ->
        {%{"v" => "-0"}, handles}

      is_exception(value) and Errors.is_error(value) ->
        {%{"e" => %{"m" => value.message, "n" => value._name || "", "s" => value._stack || ""}},
         handles}

      is_exception(value) ->
        {%{
           "e" => %{"m" => Exception.message(value), "n" => inspect(value.__struct__), "s" => ""}
         }, handles}

      is_boolean(value) ->
        {%{"b" => value}, handles}

      is_number(value) ->
        {%{"n" => value}, handles}

      is_binary(value) ->
        {%{"s" => value}, handles}

      is_struct(value, URI) ->
        {%{"u" => URI.to_string(value)}, handles}

      is_struct(value, Regex) ->
        {%{"r" => %{"p" => Regex.source(value), "f" => StrUtils.escape_regex_flags(value)}},
         handles}

      Map.has_key?(visitor_info[:visited], value) ->
        {%{"ref" => visitor_info[:visited][value]}, handles}

      is_list(value) ->
        id = VisitorInfo.visit(visitor_info, value)

        {a, handles} =
          Enum.map_reduce(value, handles, fn e, handles ->
            serialize_value(e, handles, visitor_info)
          end)

        {%{"a" => a, "id" => id}, handles}

      is_map(value) and not is_struct(value) ->
        id = VisitorInfo.visit(visitor_info, value)

        {o, handles} =
          Enum.map_reduce(value, handles, fn {name, v}, handles ->
            {sv, handles} = serialize_value(v, handles, visitor_info)
            {%{"k" => to_string(name), "v" => sv}, handles}
          end)

        {%{"o" => o, "id" => id}, handles}

      true ->
        {%{"v" => "undefined"}, handles}
    end
  end

  defp is_negative_zero(value), do: <<value::float>> == <<-0.0::float>>

  # upstream: _js_handle.py:213
  def serialize_argument(arg \\ nil) do
    handles = []
    {value, handles} = serialize_value(arg, handles)
    %{"value" => value, "handles" => handles}
  end

  # upstream: _js_handle.py:219
  def parse_value(value, refs \\ nil) do
    refs = if refs == nil, do: %{}, else: refs

    cond do
      value == nil ->
        nil

      not is_map(value) ->
        value

      Map.has_key?(value, "ref") ->
        refs[value["ref"]]

      Map.has_key?(value, "v") ->
        case value["v"] do
          "Infinity" -> :infinity
          "-Infinity" -> :neg_infinity
          "-0" -> -0.0
          "NaN" -> :nan
          "undefined" -> nil
          "null" -> nil
          v -> v
        end

      Map.has_key?(value, "u") ->
        URI.parse(value["u"])

      Map.has_key?(value, "bi") ->
        String.to_integer(value["bi"])

      Map.has_key?(value, "e") ->
        error = Errors.Error.new(value["e"]["m"])
        error = %{error | _name: value["e"]["n"]}
        error = %{error | _stack: value["e"]["s"]}
        error

      Map.has_key?(value, "r") ->
        case Regex.compile(value["r"]["p"], value["r"]["f"]) do
          {:ok, r} -> r
          # JavaScript-only syntax has no Regex equivalent.
          _ -> value
        end

      # (refs bookkeeping for cyclic arrays/objects: impossible in immutable data)
      Map.has_key?(value, "a") ->
        Enum.map(value["a"], &parse_value(&1, refs))

      # ("d" dates and "ta" typed arrays omitted in prototype)
      Map.has_key?(value, "o") ->
        Map.new(value["o"], fn e -> {e["k"], parse_value(e["v"], refs)} end)

      Map.has_key?(value, "n") ->
        value["n"]

      Map.has_key?(value, "s") ->
        value["s"]

      Map.has_key?(value, "b") ->
        value["b"]

      true ->
        value
    end
  end

  # upstream: _js_handle.py:344
  def parse_result(result), do: parse_value(result)
end
