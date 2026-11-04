defmodule Playwright.Core.ScriptsHelper do
  @moduledoc """
  upstream: Core/ScriptsHelper.cs (subset) + Transport/Converters/EvaluateArgumentValueConverter.cs (subset).
  """

  # upstream: Core/ScriptsHelper.cs:48
  def parse_evaluate_result(result_or_null), do: parse_evaluate_result_to_expando(result_or_null, %{})

  # upstream: Core/ScriptsHelper.cs:71
  def serialized_argument(arg) do
    {value, _visitor} = serialize(arg, {0, []})
    %{"value" => value, "handles" => []}
  end

  # upstream: Transport/Converters/EvaluateArgumentValueConverter.cs:48 (null/string/number/bool/dictionary/enumerable)
  defp serialize(nil, visitor), do: {%{"v" => "null"}, visitor}
  defp serialize(value, visitor) when is_binary(value), do: {%{"s" => value}, visitor}
  defp serialize(value, visitor) when is_number(value), do: {%{"n" => value}, visitor}
  defp serialize(value, visitor) when is_boolean(value), do: {%{"b" => value}, visitor}

  # `value is IDictionary dictionary && dictionary.Keys.OfType<string>().Any()`: an *empty* dictionary
  # falls through to the IEnumerable branch below and is sent as {a: [], id}. Ported as-is.
  defp serialize(value, {last_id, _} = visitor) when is_map(value) and map_size(value) > 0 do
    id = last_id + 1

    {o, visitor} =
      Enum.map_reduce(value, put_elem(visitor, 0, id), fn {k, v}, acc ->
        {sv, acc} = serialize(v, acc)
        {%{"k" => to_string(k), "v" => sv}, acc}
      end)

    {%{"o" => o, "id" => id}, visitor}
  end

  defp serialize(value, {last_id, _} = visitor) when is_map(value) or is_list(value) do
    id = last_id + 1
    {a, visitor} = Enum.map_reduce(Enum.to_list(value), put_elem(visitor, 0, id), &serialize/2)
    {%{"a" => a, "id" => id}, visitor}
  end

  # upstream: Transport/Converters/EvaluateArgumentValueConverter.cs:352 (subset)
  defp parse_evaluate_result_to_expando(nil, _refs), do: nil
  defp parse_evaluate_result_to_expando(%{"v" => "null"}, _refs), do: nil
  defp parse_evaluate_result_to_expando(%{"v" => "undefined"}, _refs), do: nil
  defp parse_evaluate_result_to_expando(%{"v" => v}, _refs), do: v
  defp parse_evaluate_result_to_expando(%{"b" => b}, _refs), do: b
  defp parse_evaluate_result_to_expando(%{"s" => s}, _refs), do: s
  defp parse_evaluate_result_to_expando(%{"n" => n}, _refs), do: n
  defp parse_evaluate_result_to_expando(%{"o" => o}, refs), do: Map.new(o, &{&1["k"], parse_evaluate_result_to_expando(&1["v"], refs)})
  defp parse_evaluate_result_to_expando(%{"a" => a}, refs), do: Enum.map(a, &parse_evaluate_result_to_expando(&1, refs))
  defp parse_evaluate_result_to_expando(other, _refs), do: other
end
