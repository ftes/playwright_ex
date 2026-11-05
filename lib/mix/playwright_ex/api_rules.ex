defmodule Mix.PlaywrightEx.ApiRules do
  @moduledoc """
  Elixir rules for `mix playwright_ex.gen.api`, applied to the JS view of `api.json`
  (the counterpart of the Python client's `python_rules`).

  Every class and member left after these rules is generated, and the facade calls the client
  directly, so a member the client lacks is a compile warning. What is out of scope is dropped
  here, each with its reason.

    * Drops JS-only classes the Elixir client has no use for (`@dropped_classes`), and every
      member, argument and option whose type refers to one of them, also from unions
      (`URLPattern` of `url:`).
    * Interfaces the user implements (`@callback_objects`: `logger: Logger`) are no classes but
      objects of functions, one per method, with the JS keys (`logger: %{isEnabled: fn name,
      severity -> ... end, log: fn name, severity, message, args, hints -> ... end}`).
    * Drops JS-only members (`@dropped_members`), and options the JS client does not take
      (`@dropped_options`: `$eval` asserts at most 3 arguments).
    * Exception classes (`TimeoutError`) are exception modules, not handles: dropped as classes, a
      property holding one (`playwright.errors.TimeoutError`) holds the module.
    * `removeAllListeners(type)` takes an `event`, as `on/3` does (atoms accepted).
    * A storage state (`storageState/1` results, `storageState` options and arguments) is an open
      object (`"open"`): it has more fields than the docs list (`credentials`, IndexedDB), so the
      facade passes it back unchecked. So are `addCookies(cookies)`: `cookies()` results carry
      protocol-only fields (`_crHasCrossSiteAncestor`) and must round-trip.
    * Documents the Elixir forms of `timeout` and `signal` (a `PlaywrightEx.AbortSignal`), and
      drops notes that recommend the test runner's options instead (`Tracing`).
    * Page functions (`expression`, a `[function]|[string]` in JS) and init scripts (`script`)
      are JS source strings.
    * Classes whose emitters take any string as an event (`@open_events`: a `CDPSession` emits
      every CDP event under its method name) are marked `"openEvents"`.
    * Waits: the JS members that the Python client has as `expect_*` (`waitForEvent`,
      `waitForRequest`, `waitForNavigation`, ...) return a promise handle (`"promise"`), as JS
      code starts them without `await`. `waitForEvent` takes Python's arguments (`event`, then
      options with `predicate` and `timeout`, plus the JS `signal`), not the JS `optionsOrPredicate`.
    * Route handlers (`function(Route, Request)`) may also take only the route, as in the
      Python client.
    * Device descriptors (`Playwright.devices`) have the option keys of `Browser.newContext`
      (`user_agent:`), as in the Python client, so `new_context(browser, devices["iPhone 6"])`
      takes one as JS spreads it (`"options"`: the member whose options they are). `newContext` and
      `newPage` take their `defaultBrowserType` and ignore it (`@extra_options`, Python's too).
    * Callback forms: every Python `expect_*` member (`expect_popup`) is added as a member with
      a `"callback"`: the JS member it starts (`waitForEvent`), and the event for those that have
      none in JS (`@callback_events`).

    * Assertions: `LocatorAssertions`, `PageAssertions` and `APIResponseAssertions` become one
      class, `Expect` (`PlaywrightEx.Expect`): `expect(locator).toHaveText(...)` is
      `Expect.to_have_text(locator, ...)`, as upstream's matchers are one set of functions on the
      receiver. Each matcher has a `"matcher"` (its JS name, `isNot`, the receiver classes) and a
      `not` form (`not_to_have_text`, the Python name of `expect(x).not.toHaveText`). Matchers of
      both Locator and Page (`toMatchAriaSnapshot`) take either. The `not` property is dropped, as
      are overloads, except that `toHaveAttribute(name, options)` makes `value` optional.
      `toHaveScreenshot` takes the snapshot file as a `path` option instead of the `name` that
      the test runner resolves (`to_have_screenshot(page, path: "home.png")`). Their option docs
      name `config :playwright_ex, :expect` for the runner's `TestConfig.expect`.
  """

  # BrowserServer: `launchServer` is out of scope (PLAN), browsers run in the driver or remote.
  # Logger: an interface, see `@callback_objects`.
  # GenericAssertions, SnapshotAssertions: jest's `expect(value)`, `toMatchSnapshot` (test runner).
  # PlaywrightAssertions: `expect(locator)` itself; the matchers are functions of the receiver (`Expect`).
  # URLPattern: a JS global (`url` matchers), dropped from unions.
  # Electron, Android and `connectOverCDP(transport)` are not in the JS view of api.json.
  @dropped_classes ~w(BrowserServer Logger GenericAssertions SnapshotAssertions PlaywrightAssertions URLPattern)

  # Interfaces implemented by the user: a type naming one is an object of functions.
  @callback_objects ~w(Logger)

  # "Class.member"
  # BrowserType.launchServer: out of scope (PLAN); also dropped with BrowserServer, its result.
  @dropped_members ~w(BrowserType.launchServer)

  # Exceptions (`PlaywrightEx.Client.Errors.TimeoutError`), JS classes in api.json.
  @exception_classes ~w(TimeoutError)

  # `session.on("Network.requestWillBeSent", ...)`: types.d.ts overloads `on` per CDP event.
  @open_events ~w(CDPSession)

  # "Class.member" => options the docs do not describe (`python_rules.js` `extraOptions`).
  @extra_options %{
    "Browser.newContext" => ["defaultBrowserType"],
    "Browser.newPage" => ["defaultBrowserType"]
  }

  # "Class.member" => the member whose options its dictionary values are.
  @descriptors %{"Playwright.devices" => "Browser.newContext"}

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
  @expect_timeout_doc "Time to retry the assertion for in milliseconds. Defaults to `timeout` in " <>
                        "`config :playwright_ex, :expect` (`5000` if not set, see `PlaywrightEx.Matchers.Expect`)."
  @signal_doc "In Elixir, a `PlaywrightEx.AbortSignal` (`PlaywrightEx.AbortController.signal/1`)."

  # Assertion classes and the class of their receiver (`expect(receiver)`).
  @assertions %{"LocatorAssertions" => "Locator", "PageAssertions" => "Page", "APIResponseAssertions" => "APIResponse"}

  # "Class.member.arg" that an overload without it makes optional.
  @optional_args ~w(LocatorAssertions.toHaveAttribute.value)

  @doc """
  Applies the rules to the decoded `api.json` classes (the JS view), with the Python view
  (`python`) for the waits and their callback forms.
  """
  def apply(classes, python) do
    classes = classes |> callback_objects() |> expect_class()

    for class <- classes, class["name"] not in @dropped_classes, class["name"] not in @exception_classes do
      expects = expect_members(python, class["name"])

      members =
        for member <- class["members"],
            "#{class["name"]}.#{member["name"]}" not in @dropped_members,
            keep?(member["type"]),
            do:
              member
              |> wait(expects)
              |> event_type()
              |> storage_state()
              |> extra_options("#{class["name"]}.#{member["name"]}")
              |> descriptors("#{class["name"]}.#{member["name"]}")
              |> Map.update("spec", nil, &runner_notes/1)
              |> member("#{class["name"]}.#{member["name"]}" in @dropped_options)

      callbacks = for expect <- expects, do: expect |> callback(class, members) |> member(false)

      Map.merge(class, %{
        "spec" => runner_notes(class["spec"]),
        "members" => members ++ callbacks,
        "openEvents" => class["name"] in @open_events
      })
    end
  end

  # Notes that point to the test runner's options instead (`Tracing`: "enable tracing in your
  # config file").
  defp runner_notes(spec) when is_list(spec),
    do: Enum.reject(spec, &(&1["type"] == "note" and inspect(&1["children"]) =~ "/docs/api/class-testoptions"))

  defp runner_notes(spec), do: spec

  # `logger: Logger` is `logger: {isEnabled: function, log: function}`, the methods as functions.
  defp callback_objects(classes) do
    objects =
      for %{"name" => name} = class <- classes, name in @callback_objects, into: %{} do
        properties =
          for method <- class["members"] do
            type = %{
              "name" => "function",
              "args" => Enum.map(method["args"], & &1["type"]),
              "returnType" => method["type"]
            }

            method |> Map.drop(["args"]) |> Map.merge(%{"kind" => "property", "type" => type})
          end

        {name, %{"name" => "Object", "expression" => "[#{name}]", "properties" => properties}}
      end

    replace_types(classes, objects)
  end

  # Types are maps with a `name` (classes have `members`).
  defp replace_types(%{"name" => name} = type, objects)
       when is_map_key(objects, name) and not is_map_key(type, "members"),
       do: objects[name]

  defp replace_types(map, objects) when is_map(map), do: Map.new(map, fn {k, v} -> {k, replace_types(v, objects)} end)
  defp replace_types(list, objects) when is_list(list), do: Enum.map(list, &replace_types(&1, objects))
  defp replace_types(value, _objects), do: value

  # The assertion classes merged into `Expect`, after the other classes.
  defp expect_class(classes) do
    {assertions, others} = Enum.split_with(classes, &Map.has_key?(@assertions, &1["name"]))

    matchers =
      for class <- Enum.sort_by(assertions, &(&1["name"] != "LocatorAssertions")),
          member <- class["members"],
          member["kind"] == "method" and member["overloadIndex"] == 0,
          do: matcher(class, member)

    members =
      matchers
      |> Enum.group_by(& &1["alias"])
      |> Map.values()
      |> Enum.sort_by(fn [first | _] -> Enum.find_index(matchers, &(&1 == first)) end)
      |> Enum.map(&merge_receivers/1)
      |> Enum.flat_map(&[&1, not_matcher(&1)])

    spec = [
      %{
        "type" => "text",
        "text" =>
          "Web-first assertions: the methods of `LocatorAssertions`, `PageAssertions` and `APIResponseAssertions`, " <>
            "as functions of their receiver. `expect(locator).toHaveText(expected)` is " <>
            "`to_have_text(locator, expected)`, `expect(locator).not.toHaveText(expected)` is " <>
            "`not_to_have_text(locator, expected)`. They retry until the expectation is met or the timeout " <>
            "(5 seconds by default, see the configuration in `PlaywrightEx.Matchers.Expect`) passes, then return `:ok` or `{:error, %PlaywrightEx.Matchers.MatcherHint.ExpectError{}}` " <>
            "whose `matcherResult` mirrors JS; the bang forms raise `ExUnit.AssertionError`."
      }
      | Enum.find(assertions, &(&1["name"] == "LocatorAssertions"))["spec"]
    ]

    others ++ [%{"name" => "Expect", "since" => "v1.17", "spec" => spec, "extends" => nil, "members" => members}]
  end

  defp matcher(class, member) do
    args =
      for arg <- member["args"] do
        arg = expect_options(arg)

        if "#{class["name"]}.#{member["alias"]}.#{arg["name"]}" in @optional_args,
          do: %{arg | "required" => false},
          else: arg
      end

    receiver = Map.fetch!(@assertions, class["name"])
    {member, args} = screenshot_path(member, args)

    Map.merge(member, %{
      "args" => args,
      "matcher" => %{"name" => member["alias"], "isNot" => false, "receivers" => [receiver]}
    })
  end

  # Matcher options: the test runner's `TestConfig.expect` is `config :playwright_ex, :expect`.
  defp expect_options(%{"name" => "options", "type" => %{"properties" => props}} = options) do
    props =
      for prop <- props do
        if prop["name"] == "timeout",
          do: %{prop | "spec" => [%{"type" => "text", "text" => @expect_timeout_doc}]},
          else: Map.update!(prop, "spec", &expect_config_doc/1)
      end

    put_in(options, ["type", "properties"], props)
  end

  defp expect_options(arg), do: arg

  defp expect_config_doc(text) when is_binary(text),
    do: String.replace(text, "`TestConfig.expect`", "`config :playwright_ex, :expect` (`PlaywrightEx.Matchers.Expect`)")

  defp expect_config_doc(spec) when is_list(spec), do: Enum.map(spec, &expect_config_doc/1)
  defp expect_config_doc(node) when is_map(node), do: Map.new(node, fn {k, v} -> {k, expect_config_doc(v)} end)
  defp expect_config_doc(value), do: value

  # `toHaveScreenshot(name, options)`: no test runner resolves `name`, `path` is an option.
  defp screenshot_path(%{"alias" => "toHaveScreenshot"} = member, args) do
    [%{"name" => "name"} = name, %{"name" => "options"} = options] = args

    path = %{
      name
      | "name" => "path",
        "alias" => "path",
        "required" => false,
        "type" => %{"expression" => "[string]", "name" => "string"},
        "spec" => [
          %{
            "type" => "text",
            "text" =>
              "Required. The snapshot file. Must have a `.png` or `.webp` extension, the screenshot is captured in the " <>
                "corresponding format. Both formats are lossless. A missing snapshot is written (see `:update_snapshots` " <>
                "in the configuration of `PlaywrightEx.Matchers.Expect`); on failure the `-actual`, `-diff` and " <>
                "`-previous` images are written next to it."
          }
        ]
    }

    options = update_in(options, ["type", "properties"], &[path | &1])

    usage = %{
      "type" => "code",
      "codeLang" => "elixir",
      "lines" => [~s{Expect.to_have_screenshot!(page, path: "test/snapshots/image.png")}]
    }

    spec =
      member["spec"]
      |> Enum.reject(&(&1["text"] == "Note that screenshot assertions only work with Playwright test runner."))
      |> Enum.map(&if(&1["type"] == "code", do: usage, else: &1))

    {%{member | "spec" => spec}, [options]}
  end

  defp screenshot_path(member, args), do: {member, args}

  # A matcher of several assertion classes: one member with every receiver and every option.
  defp merge_receivers([member]), do: member

  defp merge_receivers([first | rest]) do
    receivers = Enum.flat_map([first | rest], & &1["matcher"]["receivers"])

    props = for m <- [first | rest], %{"name" => "options"} = arg <- m["args"], p <- arg["type"]["properties"], do: p
    props = Enum.uniq_by(props, & &1["name"])

    args =
      for arg <- first["args"],
          do: if(arg["name"] == "options", do: put_in(arg, ["type", "properties"], props), else: arg)

    put_in(%{first | "args" => args}, ["matcher", "receivers"], receivers)
  end

  # `expect(x).not.toHaveText(...)`: Python's `not_to_have_text`.
  defp not_matcher(member) do
    name = "not" <> String.capitalize(String.first(member["alias"])) <> String.slice(member["alias"], 1..-1//1)
    arity = 1 + length(member["args"])

    Map.merge(member, %{
      "name" => name,
      "alias" => name,
      "spec" => [
        %{
          "type" => "text",
          "text" =>
            "The opposite of `#{Macro.underscore(member["alias"])}/#{arity}`: `expect(x).not.#{member["alias"]}(...)` in JS."
        }
      ],
      "matcher" => %{member["matcher"] | "isNot" => true}
    })
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
            do: js_options(expect["args"], member["args"]),
            else: member["args"]

        Map.merge(member, %{"promise" => expect["alias"], "args" => args})
    end
  end

  # Python's arguments, with the JS-only options of the JS member (`signal`).
  defp js_options(args, js_args) do
    js_props = for %{"name" => "options"} = arg <- js_args, p <- arg["type"]["properties"], do: p
    Enum.map(args, &add_missing_options(&1, js_props))
  end

  defp add_missing_options(%{"name" => "options"} = arg, props) do
    names = for p <- arg["type"]["properties"], do: p["name"]
    update_in(arg, ["type", "properties"], &(&1 ++ Enum.reject(props, fn p -> p["name"] in names end)))
  end

  defp add_missing_options(arg, _props), do: arg

  # `expect_popup(page, action, options)`: starts the JS member (or `waitForEvent(event)`), runs `action`.
  defp callback(expect, class, members) do
    key = "#{class["name"]}.#{expect["name"]}"

    {call, event, type, js} =
      case Enum.find(members, &(&1["name"] == expect["name"])) do
        %{} = js ->
          {js["alias"], nil, js["type"], js}

        nil ->
          {"waitForEvent", Map.fetch!(@callback_events, key), hd(expect["type"]["templates"]),
           Enum.find(members, &(&1["name"] == "waitForEvent"))}
      end

    Map.merge(expect, %{
      "callback" => %{"call" => call, "event" => event},
      "type" => type,
      "args" => js_options(expect["args"], js["args"])
    })
  end

  # `removeAllListeners(type)`: `type` is the event (`on(event, listener)`).
  defp event_type(%{"name" => "removeAllListeners"} = member) do
    args = for arg <- member["args"], do: if(arg["name"] == "type", do: %{arg | "name" => "event"}, else: arg)
    %{member | "args" => args}
  end

  defp event_type(member), do: member

  defp extra_options(member, key) do
    case @extra_options[key] do
      nil ->
        member

      names ->
        %{
          member
          | "args" => Enum.map(member["args"], &add_options(&1, Enum.map(names, fn name -> extra_option(name) end)))
        }
    end
  end

  defp add_options(%{"name" => "options"} = arg, props), do: update_in(arg, ["type", "properties"], &(&1 ++ props))
  defp add_options(arg, _props), do: arg

  defp extra_option("defaultBrowserType" = name) do
    %{
      "name" => name,
      "alias" => name,
      "kind" => "property",
      "langs" => %{},
      "required" => false,
      "since" => "v1.8",
      "type" => %{"expression" => "[string]", "name" => "string"},
      "spec" => [
        %{
          "type" => "text",
          "text" =>
            "Ignored: the browser type of a device descriptor (`PlaywrightEx.Playwright.devices/1`), so one can be passed as options."
        }
      ]
    }
  end

  defp descriptors(member, key) do
    case @descriptors[key] do
      nil ->
        member

      options ->
        text =
          "In Elixir, a descriptor has the snake_case keys of the options (`user_agent:`), as in the Python client: " <>
            "`Browser.new_context(browser, devices[\"iPhone 6\"])`."

        Map.merge(member, %{"options" => options, "spec" => member["spec"] ++ [%{"type" => "text", "text" => text}]})
    end
  end

  defp storage_state(%{"name" => "storageState", "kind" => "method"} = member),
    do: %{member | "type" => open(member["type"])}

  defp storage_state(member), do: member

  # Nested objects too (an origin has `indexedDB`).
  defp open(%{"union" => union} = type) when is_list(union), do: %{type | "union" => Enum.map(union, &open/1)}
  defp open(%{"name" => "Array", "templates" => [item]} = type), do: %{type | "templates" => [open(item)]}

  defp open(%{"properties" => props} = type) when is_list(props),
    do: Map.merge(type, %{"open" => true, "properties" => Enum.map(props, &%{&1 | "type" => open(&1["type"])})})

  defp open(type), do: type

  defp member(member, drop_options?) do
    args =
      for arg <- member["args"],
          keep?(arg["type"]),
          not (drop_options? and arg["name"] == "options"),
          do: arg |> expression() |> route_handler() |> property()

    %{
      member
      | "args" => args,
        "type" => if(member["kind"] == "property", do: type_of(member["type"]), else: member["type"])
    }
  end

  defp expression(%{"name" => name, "type" => %{"union" => union} = type} = arg)
       when name in ["expression", "script"] and is_list(union) do
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

  defp property(%{"name" => "signal", "type" => %{"name" => "AbortSignal"}} = property),
    do: Map.update(property, "spec", [], &(&1 ++ [%{"type" => "text", "text" => @signal_doc}])) |> type()

  # `errors: { TimeoutError: typeof TimeoutError }`: the exception module.
  defp property(%{"name" => name, "type" => %{"name" => "function"}} = property) when name in @exception_classes,
    do: %{property | "type" => %{"name" => "typeof", "templates" => [%{"name" => name}]}}

  defp property(%{"name" => "storageState", "type" => type} = property), do: type(%{property | "type" => open(type)})
  defp property(%{"name" => "cookies", "type" => type} = property), do: type(%{property | "type" => open(type)})
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
