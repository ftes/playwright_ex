defmodule Mix.PlaywrightEx.ApiRules do
  @moduledoc """
  Elixir rules for `mix playwright_ex.gen.api`, applied to the JS view of `api.json`
  (the counterpart of the Python client's `python_rules`).

    * Drops JS-only classes the Elixir client has no use for (`@dropped_classes`), and every
      member, argument and option whose type refers to one of them (`logger: Logger`, and the
      DOM `AbortSignal` of `signal:` options), also from unions (`URLPattern` of `url:`).
    * Drops JS-only members (`@dropped_members`), and options the JS client does not take
      (`@dropped_options`: `$eval` asserts at most 3 arguments).
    * Documents the Elixir forms of `timeout`.
    * Page functions (`expression`, a `[function]|[string]` in JS) are JS source strings.
    * Waits: the JS members that the Python client has as `expect_*` (`waitForEvent`,
      `waitForRequest`, `waitForNavigation`, ...) return a promise handle (`"promise"`), as JS
      code starts them without `await`. `waitForEvent` takes Python's arguments (`event`, then
      options with `predicate` and `timeout`), not the JS `optionsOrPredicate`.
    * Route handlers (`function(Route, Request)`) may also take only the route, as in the
      Python client.
    * Callback forms: every Python `expect_*` member (`expect_popup`) is added as a member with
      a `"callback"`: the JS member it starts (`waitForEvent`), and the event for those that have
      none in JS (`@callback_events`).

  Still to come with the classes they need: the `to_have_screenshot` path rule.
  """

  # URLPattern: a JS global (`url` matchers), dropped from unions.
  @dropped_classes ~w(BrowserServer Logger GenericAssertions SnapshotAssertions AbortSignal URLPattern)

  # "Class.member"
  @dropped_members ~w()

  # "Class.member" whose `options` argument the client rejects.
  @dropped_options ~w(Frame.evalOnSelector Page.evalOnSelector ElementHandle.inputValue)

  # The events of the Python `expect_*` members that have no JS member (`expect_popup` is
  # `waitForEvent("popup")` in the Python client).
  @callback_events %{
    "BrowserContext.waitForConsoleMessage" => "console",
    "BrowserContext.waitForPage" => "page",
    "Page.waitForConsoleMessage" => "console",
    "Page.waitForDownload" => "download",
    "Page.waitForFileChooser" => "filechooser",
    "Page.waitForPopup" => "popup",
    "Page.waitForRequestFinished" => "requestfinished",
    "Page.waitForWebSocket" => "websocket",
    "Page.waitForWorker" => "worker"
  }

  @timeout_doc "In Elixir, `:infinity` is accepted too (the same as `0`)."

  @doc """
  Applies the rules to the decoded `api.json` classes (the JS view), with the Python view
  (`python`) for the waits and their callback forms.
  """
  def apply(classes, python) do
    for class <- classes, class["name"] not in @dropped_classes do
      expects = expect_members(python, class["name"])

      members =
        for member <- class["members"],
            "#{class["name"]}.#{member["name"]}" not in @dropped_members,
            keep?(member["type"]),
            do: member |> wait(expects) |> member("#{class["name"]}.#{member["name"]}" in @dropped_options)

      callbacks = for expect <- expects, do: expect |> callback(class, members) |> member(false)
      %{class | "members" => members ++ callbacks}
    end
  end

  # Python's `expect_*` members of `class_name`, by JS name.
  defp expect_members(python, class_name) do
    with %{} = class <- Enum.find(python, &(&1["name"] == class_name)) do
      for m <- class["members"], m["kind"] == "method", String.starts_with?(m["alias"], "expect_"), do: m
    end || []
  end

  defp wait(member, expects) do
    case Enum.find(expects, &(&1["name"] == member["name"])) do
      nil ->
        member

      expect ->
        args =
          if Enum.any?(member["args"], &(&1["name"] == "optionsOrPredicate")),
            do: expect["args"],
            else: member["args"]

        Map.merge(member, %{"promise" => expect["alias"], "args" => args})
    end
  end

  # `expect_popup(page, action, options)`: starts the JS member (or `waitForEvent(event)`), runs `action`.
  defp callback(expect, class, members) do
    key = "#{class["name"]}.#{expect["name"]}"

    {call, event, type} =
      case Enum.find(members, &(&1["name"] == expect["name"])) do
        %{} = js -> {js["alias"], nil, js["type"]}
        nil -> {"waitForEvent", Map.fetch!(@callback_events, key), hd(expect["type"]["templates"])}
      end

    Map.merge(expect, %{"callback" => %{"call" => call, "event" => event}, "type" => type})
  end

  defp member(member, drop_options?) do
    args =
      for arg <- member["args"],
          keep?(arg["type"]),
          not (drop_options? and arg["name"] == "options"),
          do: arg |> expression() |> route_handler() |> property()

    %{member | "args" => args}
  end

  defp expression(%{"name" => "expression", "type" => %{"union" => union} = type} = arg) when is_list(union) do
    case Enum.reject(union, &(&1["name"] == "function")) do
      [single] -> %{arg | "type" => single}
      rest -> %{arg | "type" => %{type | "union" => rest}}
    end
  end

  defp expression(arg), do: arg

  # `handler: function(Route, Request)`: a 1-arity function (the route) is accepted too.
  defp route_handler(%{"name" => "handler", "type" => %{"name" => "function", "args" => [route, _]} = type} = arg)
       when route == %{"name" => "Route"},
       do: %{arg | "type" => %{"name" => "", "union" => [%{type | "args" => [route]}, type]}}

  defp route_handler(arg), do: arg

  defp property(%{"name" => "timeout"} = property),
    do: Map.update(property, "spec", [], &(&1 ++ [%{"type" => "text", "text" => @timeout_doc}])) |> type()

  defp property(property), do: type(property)

  defp type(%{"type" => type} = property) when is_map(type), do: %{property | "type" => type_of(type)}
  defp type(property), do: property

  defp type_of(%{"properties" => props} = type) when is_list(props),
    do: %{type | "properties" => for(p <- props, keep?(p["type"]), do: property(p))}

  # `url: string|RegExp|URLPattern|function`: no URLPattern in Elixir.
  defp type_of(%{"union" => union} = type) when is_list(union),
    do: %{type | "union" => for(t <- union, keep?(t), do: type_of(t))}

  defp type_of(type), do: type

  # A type that is (only) a dropped class.
  defp keep?(%{"name" => name}) when name in @dropped_classes, do: false
  defp keep?(_type), do: true
end
