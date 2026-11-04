defmodule Mix.PlaywrightEx.ApiRules do
  @moduledoc """
  Elixir rules for `mix playwright_ex.gen.api`, applied to the JS view of `api.json`
  (the counterpart of the Python client's `python_rules`).

    * Drops JS-only classes the Elixir client has no use for (`@dropped_classes`), and every
      member, argument and option whose type refers to one of them (`logger: Logger`, and the
      DOM `AbortSignal` of `signal:` options).
    * Drops JS-only members (`@dropped_members`).
    * Documents the Elixir forms of `timeout`.
    * Page functions (`expression`, a `[function]|[string]` in JS) are JS source strings.

  Still to come with the classes they need: callback forms (`expect_popup`), the
  `to_have_screenshot` path rule.
  """

  @dropped_classes ~w(BrowserServer Logger GenericAssertions SnapshotAssertions AbortSignal)

  # "Class.member"
  @dropped_members ~w()

  @timeout_doc "In Elixir, `:infinity` is accepted too (the same as `0`)."

  @doc "Applies the rules to the decoded `api.json` classes."
  def apply(classes) do
    for class <- classes, class["name"] not in @dropped_classes do
      members =
        for member <- class["members"],
            "#{class["name"]}.#{member["name"]}" not in @dropped_members,
            keep?(member["type"]),
            do: member(member)

      %{class | "members" => members}
    end
  end

  defp member(member) do
    args = for arg <- member["args"], keep?(arg["type"]), do: arg |> expression() |> property()
    %{member | "args" => args}
  end

  defp expression(%{"name" => "expression", "type" => %{"union" => union} = type} = arg) when is_list(union) do
    case Enum.reject(union, &(&1["name"] == "function")) do
      [single] -> %{arg | "type" => single}
      rest -> %{arg | "type" => %{type | "union" => rest}}
    end
  end

  defp expression(arg), do: arg

  defp property(%{"name" => "timeout"} = property),
    do: Map.update(property, "spec", [], &(&1 ++ [%{"type" => "text", "text" => @timeout_doc}])) |> type()

  defp property(property), do: type(property)

  defp type(%{"type" => %{"properties" => props} = type} = property) when is_list(props),
    do: %{property | "type" => %{type | "properties" => for(p <- props, keep?(p["type"]), do: property(p))}}

  defp type(property), do: property

  # A type that is (only) a dropped class.
  defp keep?(%{"name" => name}) when name in @dropped_classes, do: false
  defp keep?(_type), do: true
end
