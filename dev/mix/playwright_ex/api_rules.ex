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
    * `waitForTimeout(timeout)` is a duration (`"duration"`), not a timeout: no `:infinity`.
    * Documents the Elixir forms of `timeout` and `signal` (a `PlaywrightEx.AbortSignal`), and
      drops notes that recommend the test runner's options instead (`Tracing`).
    * Page functions (`expression`, a `[function]|[string]` in JS) and init scripts (`script`)
      are JS source strings.
    * Classes whose emitters take any string as an event (`@open_events`: a `CDPSession` emits
      every CDP event under its method name) are marked `"openEvents"`.
    * Waits: the JS members that the Python client has as `expect_*` (`waitForEvent`,
      `waitForRequest`, `waitForNavigation`, ...) return a promise handle (`"promise"`), as JS
      code starts them without `await`.
    * An `optionsOr<Name>` argument (`[function]|[Object]`, `waitForEvent(event, optionsOrPredicate)`)
      becomes the `options` (the object's properties, then the options'), marked `"function"`:
      the facade takes a function in their place as option `<name>`. So do the callback forms
      that start the member (`expect_event(page, event, action, predicate)`).
    * Route handlers (`function(Route, Request)`) may also take only the route, as in the
      Python client.
    * An optional argument right before the options that is never a list or a plain map (a
      string, regex, enum or handle: `toHaveAttribute(name, value?, options?)`,
      `waitForLoadState(state?, options?)`) is marked `"orOptions"`: the options may take its
      place (`to_have_attribute(locator, "disabled", timeout: 1)`).
    * Device descriptors (`Playwright.devices`) have the option keys of `Browser.newContext`
      (`user_agent:`), as in the Python client, so `new_context(browser, devices["iPhone 6"])`
      takes one as JS spreads it (`"options"`: the member whose options they are). `newContext` and
      `newPage` take their `defaultBrowserType` and ignore it (`@extra_options`, Python's too).
    * Options that JS code fills with a result of the member (`@result_options`:
      `credentials.create(known.rpId, known)`) are marked `"result"`: the facade also takes such a
      result (a map with the JS keys) as the options, ignoring its fields that are no options
      (`rpId`, which the positional argument overrides in the client too).
    * An option map of `selectOption` also takes `valueOrLabel`: the protocol and the JS client
      accept it and only JS's types leave it out, and a list can't mix strings with option maps.
    * Errors thrown in the page (`@thrown_values`: `WebError.error`) are any thrown value, as
      `parseError` returns it (`throw "x"` is `"x"`): typed `Error|any`, with a note.
    * Elixir notes appended to a member's docs (`@notes`: `getProperties` returns a map, which
      does not keep the property order).
    * Prose the generator's rules for JS names in docs cannot fix (`@prose_overrides`: JS calls
      with arguments, upstream slips such as `filePaths`), and inline code they must leave alone
      (`@prose_keep`: `getByRole`'s `disabled`, also the HTML attribute).
    * Callback forms: every Python `expect_*` member (`expect_popup`) is added as a member with
      a `"callback"`: the JS member it starts (`waitForEvent`), and the event for those that have
      none in JS (`@callback_events`).

    * Assertions: `LocatorAssertions`, `PageAssertions` and `APIResponseAssertions` become one
      class, `Expect` (`PlaywrightEx.Expect`): `expect(locator).toHaveText(...)` is
      `Expect.to_have_text(locator, ...)`, as upstream's matchers are one set of functions on the
      receiver. Each matcher has a `"matcher"` (its JS name, `isNot`, the receiver classes) and a
      `not` form (`not_to_have_text`, the Python name of `expect(x).not.toHaveText`). Matchers of
      both Locator and Page (`toMatchAriaSnapshot`) take either. The `not` property is the member
      `not_` (`"negate"`: the receiver classes), as `and_`/`or_`, Java's `not()`: it wraps the
      receiver, which the matchers take too (`locator |> Expect.not_() |> Expect.to_have_text("x")`).
      Overloads are dropped, except that `toHaveAttribute(name, options)` makes `value` optional.
      `toHaveScreenshot` takes the snapshot file as a `path` option instead of the `name` that
      the test runner resolves (`to_have_screenshot(page, path: "home.png")`), as does
      `toMatchAriaSnapshot`, in place of `expected` (`to_match_aria_snapshot(page, path: "a.aria.yml")`).
      Their option docs
      name `config :playwright_ex, :expect` for the runner's `TestConfig.expect`.
  """

  # BrowserServer: `launchServer` is out of scope (architecture: Generated facade), browsers run
  # in the driver or remote.
  # Logger: an interface, see `@callback_objects`.
  # GenericAssertions, SnapshotAssertions: jest's `expect(value)`, `toMatchSnapshot` (test runner).
  # PlaywrightAssertions: `expect(locator)` itself; the matchers are functions of the receiver (`Expect`).
  # URLPattern: a JS global (`url` matchers), dropped from unions.
  # Electron, Android and `connectOverCDP(transport)` are not in the JS view of api.json.
  @dropped_classes ~w(BrowserServer Logger GenericAssertions SnapshotAssertions PlaywrightAssertions URLPattern)

  # Interfaces implemented by the user: a type naming one is an object of functions.
  @callback_objects ~w(Logger)

  # "Class.member"
  # BrowserType.launchServer: out of scope (architecture: Generated facade); also dropped with
  # BrowserServer, its result.
  @dropped_members ~w(BrowserType.launchServer)

  # Exceptions (`PlaywrightEx.TimeoutError`), JS classes in api.json.
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

  # "Class.member" whose options may be one of its results (`create(known.rpId, known)`).
  @result_options ~w(Credentials.create)

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
                        "`config :playwright_ex, :expect` (`5000` if not set, see the configuration in `PlaywrightEx.Expect`)."
  @signal_doc "In Elixir, a `PlaywrightEx.AbortSignal` (`PlaywrightEx.AbortController.signal/1`)."

  # Assertion classes and the class of their receiver (`expect(receiver)`).
  @assertions %{"LocatorAssertions" => "Locator", "PageAssertions" => "Page", "APIResponseAssertions" => "APIResponse"}

  # Prose the generic rules of `mix playwright_ex.gen.api` (JS names in prose, as Elixir has them)
  # get wrong or cannot reach: "Class.member" (or "Class" for the class docs) => [{upstream text,
  # Elixir text}]. Each upstream text must still be there, so a version bump that changes it fails.
  @timeout_doc_from "The default value can be changed by using the [`method: BrowserContext.setDefaultTimeout`]."
  @page_timeout_doc "[`method: Page.setDefaultTimeout`] or [`method: BrowserContext.setDefaultTimeout`]."
  @set_input_files [{"`filePaths`", "`files`"}]
  @prose_overrides %{
    # JS calls with arguments: the generic rule links only `receiver.member()`.
    "APIRequestContext" => [
      {"`page.request` is a shortcut for `page.context().request`",
       "[`method: Page.request`] is a shortcut for [`method: BrowserContext.request`] of [`method: Page.context`]"}
    ],
    "Page.pdf" => [
      {"`page.pdf({width: 100})`", "`Page.pdf(page, width: 100)`"},
      {"`page.pdf({width: '100px'})`", "`Page.pdf(page, width: \"100px\")`"},
      {"`page.pdf({width: '10cm'})`", "`Page.pdf(page, width: \"10cm\")`"}
    ],
    "Locator.within" => [
      {"`page.getByRole('cell').nth(2)`", "`Page.get_by_role(page, :cell) |> Locator.nth(2)`"}
    ],
    "Playwright.errors" => [{"[`playwright.errors`](#playwright-errors)", "[`property: Playwright.errors`]"}],
    # `element.tap()` means the locator's.
    "Locator.tap" => [{"`element.tap()`", "[`method: Locator.tap`]"}],
    "Locator.dblclick" => [{"`element.dblclick()`", "[`method: Locator.dblclick`]"}],
    # The argument is `files`.
    "ElementHandle.setInputFiles" => @set_input_files,
    "FileChooser.setFiles" => @set_input_files,
    "Frame.setInputFiles" => @set_input_files,
    "Locator.setInputFiles" => @set_input_files,
    "Page.setInputFiles" => @set_input_files,
    # `colorScheme` and `media` are options.
    "Page.emulateMedia" => [
      {"through the `media` argument", "through the `media` option"},
      {"using the `colorScheme` argument", "using the `colorScheme` option"}
    ],
    # The timeout of a page's waits also follows `Page.setDefaultTimeout` (`TimeoutSettings`); also
    # their callback forms (`expect_event`).
    "Page.waitForEvent" => [
      {@timeout_doc_from, "The default value can be changed with " <> @page_timeout_doc},
      {"`*.on(event)`", "[`method: Page.on`]"}
    ],
    "Worker.waitForEvent" => [
      {@timeout_doc_from, "The default value can be changed with its page's " <> @page_timeout_doc},
      {"`*.on(event)`", "[`method: Worker.on`]"}
    ],
    "WebSocket.waitForEvent" => [
      {@timeout_doc_from, "The default value can be changed with its page's " <> @page_timeout_doc}
    ],
    # Calls return their values, `{:ok, value}`.
    "WebStorage" => [{"for the current origin via an async,", "for the current origin via a"}],
    # Listeners are added with the facade's `on/3` & co., not Node's EventEmitter.
    "Page" => [
      {"which can be handled using any of Node's native [`EventEmitter`](https://nodejs.org/api/events.html#events_class_eventemitter) " <>
         "methods, such as `on`, `once` or `removeListener`.",
       "which can be handled with [`method: Page.on`], [`method: Page.once`] or [`method: Page.off`]."}
    ],
    # An upstream slip ("Throws for elements").
    "Locator.inputValue" => [{"Throws elements that are not", "Throws for elements that are not"}]
  }

  # "Class.member" whose `Error` is a value thrown in the page: `parseError` returns any thrown
  # value, an exception only for an `Error` (upstream's type says `Error`).
  @thrown_values ~w(WebError.error Page.pageError Page.pageErrors)
  @thrown_value_note "In Elixir, this is the value thrown in the page: an exception for an `Error`, " <>
                       "else the value itself (`throw \"oops\"` gives `\"oops\"`)."

  # "Class.member" => an Elixir note appended to its docs.
  @notes %{
    # The client returns `Map<string, JSHandle>` as a map (`# deviation:` in its `get_properties`).
    "JSHandle.getProperties" =>
      "In Elixir, the result is a map of property name to handle; unlike JS's `Map`, it does not keep the property order."
  }

  # Member name => inline code the prose rules leave alone: `getByRole`'s `disabled` is also the
  # HTML attribute.
  @prose_keep %{"getByRole" => ~w(disabled)}

  # "Class.member.arg" that an overload without it makes optional.
  @optional_args ~w(LocatorAssertions.toHaveAttribute.value)

  @doc "The assertion classes, which are `Expect` (`[method: LocatorAssertions.toHaveText]` is `Expect.to_have_text/3`)."
  def assertion_classes, do: Map.keys(@assertions)

  @doc """
  Applies the rules to the decoded `api.json` classes (the JS view), with the Python view
  (`python`) for the waits and their callback forms.
  """
  def apply(classes, python) do
    classes = classes |> callback_objects() |> expect_class()
    members = for class <- classes, member <- class["members"], do: "#{class["name"]}.#{member["name"]}"

    missing = @thrown_values -- members
    if missing != [], do: raise("ApiRules: thrown values no longer match upstream: no member #{inspect(missing)}")

    class_names = MapSet.new(classes, & &1["name"])

    for class <- classes, class["name"] not in @dropped_classes, class["name"] not in @exception_classes do
      expects = expect_members(python, class["name"])

      members =
        for member <- class["members"],
            "#{class["name"]}.#{member["name"]}" not in @dropped_members,
            keep?(member["type"]),
            do:
              member
              |> options_or_function()
              |> wait(expects)
              |> event_type()
              |> storage_state()
              |> select_option()
              |> extra_options("#{class["name"]}.#{member["name"]}")
              |> descriptors("#{class["name"]}.#{member["name"]}")
              |> result_options("#{class["name"]}.#{member["name"]}" in @result_options)
              |> thrown_values("#{class["name"]}.#{member["name"]}")
              |> notes("#{class["name"]}.#{member["name"]}")
              |> Map.update("spec", nil, &runner_notes/1)
              |> member("#{class["name"]}.#{member["name"]}" in @dropped_options)
              |> or_options(class_names)
              |> prose("#{class["name"]}.#{member["name"]}")

      callbacks =
        for expect <- expects,
            do:
              expect
              |> callback(class, members)
              |> member(false)
              |> or_options(class_names)
              |> prose("#{class["name"]}.#{expect["name"]}")

      Map.merge(class, %{
        "spec" => class["spec"] |> runner_notes() |> prose_overrides(class["name"]),
        "members" => members ++ callbacks,
        "openEvents" => class["name"] in @open_events
      })
    end
  end

  defp prose(member, key) do
    member = Map.merge(member, prose_overrides(Map.take(member, ["spec", "args"]), key))

    case @prose_keep[member["name"]] do
      nil -> member
      keep -> Map.put(member, "proseKeep", keep)
    end
  end

  # The overrides of `key` in the text nodes of `term` (never in code blocks).
  defp prose_overrides(term, key) do
    Enum.reduce(Map.get(@prose_overrides, key, []), term, fn {from, to}, term ->
      if not text_contains?(term, from),
        do: raise("ApiRules: prose override for #{key} no longer matches upstream: #{inspect(from)}")

      replace_text(term, from, to)
    end)
  end

  defp text_contains?(%{"type" => "code"}, _from), do: false

  defp text_contains?(%{"text" => text} = node, from) when is_binary(text),
    do: String.contains?(String.replace(text, "↵", " "), from) or text_contains?(Map.delete(node, "text"), from)

  defp text_contains?(map, from) when is_map(map), do: Enum.any?(Map.values(map), &text_contains?(&1, from))
  defp text_contains?(list, from) when is_list(list), do: Enum.any?(list, &text_contains?(&1, from))
  defp text_contains?(_term, _from), do: false

  # Upstream breaks lines with `↵`: matched as spaces.
  defp replace_text(%{"type" => "code"} = node, _from, _to), do: node

  defp replace_text(map, from, to) when is_map(map) do
    Map.new(map, fn
      {"text", text} when is_binary(text) -> {"text", replace_soft(text, from, to)}
      {k, v} -> {k, replace_text(v, from, to)}
    end)
  end

  defp replace_text(list, from, to) when is_list(list), do: Enum.map(list, &replace_text(&1, from, to))
  defp replace_text(term, _from, _to), do: term

  defp replace_soft(text, from, to) do
    pattern = from |> String.split(" ") |> Enum.map_join("[ ↵]", &Regex.escape/1)
    # Unicode: `↵` is one character in the class.
    String.replace(text, Regex.compile!(pattern, "u"), to)
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
          do: class |> matcher(member) |> overload_examples(class)

    members =
      matchers
      |> Enum.group_by(& &1["alias"])
      |> Map.values()
      |> Enum.sort_by(fn [first | _] -> Enum.find_index(matchers, &(&1 == first)) end)
      |> Enum.map(&merge_receivers/1)
      |> Enum.flat_map(&[&1, not_matcher(&1)])

    receivers = members |> Enum.flat_map(& &1["matcher"]["receivers"]) |> Enum.uniq()
    members = [negate(Enum.find(assertions, &(&1["name"] == "LocatorAssertions")), receivers) | members]

    spec =
      [
        %{
          "type" => "text",
          "text" =>
            "Web-first assertions: the methods of `LocatorAssertions`, `PageAssertions` and `APIResponseAssertions`, " <>
              "as functions of their receiver."
        },
        %{
          "type" => "text",
          "text" =>
            "`expect(locator).toHaveText(expected)` is " <>
              "`to_have_text(locator, expected)`, `expect(locator).not.toHaveText(expected)` is " <>
              "`not_to_have_text(locator, expected)` or `locator |> not_() |> to_have_text(expected)`. They retry until the expectation is met or the timeout " <>
              "(5 seconds by default, see Configuration below) passes, then return `:ok` or `{:error, %PlaywrightEx.ExpectError{}}` " <>
              "whose `matcherResult` mirrors JS; the bang forms raise the `PlaywrightEx.ExpectError` " <>
              "([Testing with ExUnit](testing-with-exunit.md) shows how to wrap it in an `ExUnit.AssertionError`)."
        }
        | Enum.find(assertions, &(&1["name"] == "LocatorAssertions"))["spec"]
      ] ++ [%{"type" => "text", "text" => "## Configuration\n\n" <> PlaywrightEx.Matchers.Expect.__config_doc__()}]

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
    {member, args} = snapshot_path(member, args)

    Map.merge(member, %{
      "args" => args,
      "matcher" => %{"name" => member["alias"], "isNot" => false, "receivers" => [receiver]}
    })
  end

  # A member an overload makes an argument optional of shows that overload's examples too
  # (`toHaveAttribute(name)`: "Assert attribute existence").
  defp overload_examples(member, class) do
    if Enum.any?(member["args"], &("#{class["name"]}.#{member["alias"]}.#{&1["name"]}" in @optional_args)) do
      examples =
        for overload <- class["members"],
            overload["alias"] == member["alias"] and overload["overloadIndex"] != 0,
            node <- overload["spec"] || [],
            node["type"] == "code",
            do: node

      Map.update!(member, "spec", &(&1 ++ examples))
    else
      member
    end
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
    do:
      String.replace(
        text,
        "`TestConfig.expect`",
        "`config :playwright_ex, :expect` (see the configuration in `PlaywrightEx.Expect`)"
      )

  defp expect_config_doc(spec) when is_list(spec), do: Enum.map(spec, &expect_config_doc/1)
  defp expect_config_doc(node) when is_map(node), do: Map.new(node, fn {k, v} -> {k, expect_config_doc(v)} end)
  defp expect_config_doc(value), do: value

  # `toHaveScreenshot(name, options)`: no test runner resolves `name`, `path` is an option.
  defp snapshot_path(%{"alias" => "toHaveScreenshot"} = member, args) do
    [%{"name" => "name"} = name, %{"name" => "options"} = options] = args

    path =
      path_option(
        name,
        "Required. The snapshot file. Must have a `.png` or `.webp` extension, the screenshot is captured in the " <>
          "corresponding format. Both formats are lossless. A missing snapshot is written (see `:update_snapshots` " <>
          "in the configuration of `PlaywrightEx.Expect`); on failure the `-actual`, `-diff` and " <>
          "`-previous` images are written next to it."
      )

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

  # `toMatchAriaSnapshot(options)`: the overload that reads a file, whose `name` no test runner resolves.
  defp snapshot_path(%{"alias" => "toMatchAriaSnapshot"} = member, args) do
    [%{"name" => "expected"} = expected, %{"name" => "options"} = options] = args

    path =
      path_option(
        expected,
        "The snapshot file, in place of `expected`. Its content is the expected snapshot. A missing snapshot is " <>
          "written, unless `:update_snapshots` is `:none` or the matcher is negated. With " <>
          "`:update_snapshots` set to `:all` it is always rewritten, with `:changed` when it differs (see the " <>
          "configuration of `PlaywrightEx.Expect`)."
      )

    options = update_in(options, ["type", "properties"], &[path | &1])

    usage = %{
      "type" => "code",
      "codeLang" => "elixir",
      "lines" => [~s{Expect.to_match_aria_snapshot!(page, path: "test/snapshots/body.aria.yml")}]
    }

    {Map.update!(member, "spec", &(&1 ++ [usage])), [%{expected | "required" => false}, options]}
  end

  defp snapshot_path(member, args), do: {member, args}

  defp path_option(arg, doc) do
    Map.merge(arg, %{
      "name" => "path",
      "alias" => "path",
      "required" => false,
      "type" => %{"expression" => "[string]", "name" => "string"},
      "spec" => [%{"type" => "text", "text" => doc}]
    })
  end

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

  # `expect(x).not`: `not_(x)`, a negated receiver (`"negate"`), from `LocatorAssertions.not`.
  defp negate(class, receivers) do
    %{"kind" => "property"} = member = Enum.find(class["members"], &(&1["name"] == "not"))

    text =
      "In Elixir, `not_/1` wraps the receiver, which every matcher takes too: " <>
        "`locator |> Expect.not_() |> Expect.to_contain_text(\"error\")` is " <>
        "`Expect.not_to_contain_text(locator, \"error\")`. As JS has no `expect(x).not.not`, a negated " <>
        "receiver is not negated again: `not_/1` and the `not_to_*` matchers raise `ArgumentError` for one."

    Map.merge(member, %{
      "kind" => "method",
      "args" => [],
      "type" => nil,
      "spec" => member["spec"] ++ [%{"type" => "text", "text" => text}],
      "negate" => receivers
    })
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

  # `optionsOrPredicate`: one `options` argument whose place a function also takes (`"function"`).
  defp options_or_function(member) do
    case Enum.split_with(member["args"], &options_or?/1) do
      {[], _} ->
        member

      {[%{"name" => "optionsOr" <> fun} = union], args} ->
        {options, positional} = Enum.split_with(args, &(&1["name"] == "options"))
        %{"properties" => object} = Enum.find(union["type"]["union"], &(&1["name"] == "Object"))
        own = for %{"type" => %{"properties" => props}} <- options, p <- props, do: p
        # An option of both keeps the options' docs.
        props =
          for p <- Enum.uniq_by(object ++ own, & &1["name"]),
              do: Map.put(Enum.find(own, p, &(&1["name"] == p["name"])), "required", false)

        options = List.first(options) || %{union | "name" => "options", "alias" => "options"}
        {first, rest} = String.split_at(fun, 1)

        options =
          Map.merge(options, %{
            "type" => %{"name" => "Object", "properties" => props},
            "function" => String.downcase(first) <> rest
          })

        %{member | "args" => positional ++ [options]}
    end
  end

  defp options_or?(%{"name" => "optionsOr" <> _, "type" => %{"union" => union}}),
    do: Enum.map(union, & &1["name"]) |> Enum.sort() == ["Object", "function"]

  defp options_or?(_arg), do: false

  defp wait(member, expects) do
    case Enum.find(expects, &(&1["name"] == member["name"])) do
      nil -> member
      expect -> Map.put(member, "promise", expect["alias"])
    end
  end

  # Python's arguments, with the JS-only options of the JS member (`signal`), which also take its
  # function in their place (`"function"`).
  defp js_options(args, js_args) do
    js_options = Enum.find(js_args, &(&1["name"] == "options")) || %{}
    js_props = get_in(js_options, ["type", "properties"]) || []
    Enum.map(args, &add_missing_options(&1, js_props, Map.take(js_options, ["function"])))
  end

  defp add_missing_options(%{"name" => "options"} = arg, props, function) do
    names = for p <- arg["type"]["properties"], do: p["name"]

    arg
    |> update_in(["type", "properties"], &(&1 ++ Enum.reject(props, fn p -> p["name"] in names end)))
    |> Map.merge(function)
  end

  defp add_missing_options(arg, _props, _function), do: arg

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

  defp thrown_values(member, key) when key not in @thrown_values, do: member

  defp thrown_values(member, key) do
    type = thrown_value(member["type"])

    if type == member["type"],
      do: raise("ApiRules: thrown value #{key} no longer matches upstream: not typed `Error`")

    member
    |> Map.put("type", type)
    |> Map.update!("spec", &(&1 ++ [%{"type" => "text", "text" => @thrown_value_note}]))
  end

  defp thrown_value(%{"name" => "Error"} = type), do: %{"name" => "", "union" => [type, %{"name" => "any"}]}

  defp thrown_value(%{"templates" => templates} = type),
    do: %{type | "templates" => Enum.map(templates, &thrown_value/1)}

  defp thrown_value(type), do: type

  defp notes(member, key) do
    case @notes[key] do
      nil -> member
      text -> Map.update!(member, "spec", &(&1 ++ [%{"type" => "text", "text" => text}]))
    end
  end

  defp result_options(member, false), do: member

  defp result_options(%{"type" => %{"properties" => result}} = member, true) do
    text =
      "In Elixir, the options may also be a result of this function (a map with the JS keys), " <>
        "as JS passes one: `create!(credentials, known.rpId, known)`. Its fields that are no options are ignored."

    args = Enum.map(member["args"], &result_arg(&1, result, member["type"]))
    Map.merge(member, %{"args" => args, "spec" => member["spec"] ++ [%{"type" => "text", "text" => text}]})
  end

  # The result's fields that are no options are ignored (`rpId`).
  defp result_arg(%{"name" => "options"} = arg, result, type) do
    names = MapSet.new(arg["type"]["properties"], & &1["name"])
    ignored = for %{"name" => name} <- result, name not in names, do: name
    Map.put(arg, "result", %{"ignored" => ignored, "type" => type})
  end

  defp result_arg(arg, _result, _type), do: arg

  defp storage_state(%{"name" => "storageState", "kind" => "method"} = member),
    do: %{member | "type" => open(member["type"])}

  defp storage_state(member), do: member

  defp select_option(%{"name" => "selectOption", "args" => args} = member),
    do: %{member | "args" => Enum.map(args, &select_option_values/1)}

  defp select_option(member), do: member

  defp select_option_values(%{"name" => "values"} = arg),
    do: update_in(arg, ["type", "union"], fn union -> Enum.map(union, &value_or_label/1) end)

  defp select_option_values(arg), do: arg

  defp value_or_label(%{"properties" => properties} = type),
    do: %{type | "properties" => properties ++ [value_or_label_property()]}

  defp value_or_label(%{"templates" => [%{"properties" => _} = item]} = type),
    do: %{type | "templates" => [value_or_label(item)]}

  defp value_or_label(type), do: type

  defp value_or_label_property do
    %{
      "name" => "valueOrLabel",
      "alias" => "valueOrLabel",
      "kind" => "property",
      "langs" => %{},
      "required" => false,
      "since" => "v1.8",
      "type" => %{"expression" => "[string]", "name" => "string"},
      "spec" => [
        %{
          "type" => "text",
          "text" => "Matches by value or label, as a string does. Combines such a match with `index` in one list."
        }
      ]
    }
  end

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
          do: arg |> duration(member["name"]) |> expression() |> route_handler() |> property()

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

  # `waitForTimeout(timeout)`: how long to wait, `0` is no wait.
  defp duration(%{"name" => "timeout"} = arg, "waitForTimeout"), do: Map.put(arg, "duration", true)
  defp duration(arg, _member), do: arg

  defp property(%{"duration" => true} = property), do: type(property)

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

  # `name(receiver, ..., value \\ nil, options \\ [])` called as `name(receiver, ..., options)`: the
  # optional argument before the options, if no value of it is a keyword list or plain map.
  defp or_options(%{"args" => args} = member, class_names) do
    case Enum.split(args, -2) do
      {head, [%{"required" => false} = arg, %{"name" => "options"} = options]} ->
        if scalar?(arg["type"], class_names),
          do: %{member | "args" => head ++ [Map.put(arg, "orOptions", true), options]},
          else: member

      _ ->
        member
    end
  end

  @scalars ~w(string RegExp boolean int long float number null undefined)

  defp scalar?(%{"union" => union}, class_names) when is_list(union), do: Enum.all?(union, &scalar?(&1, class_names))

  defp scalar?(%{"name" => name}, class_names),
    do: name in @scalars or String.starts_with?(name, "\"") or MapSet.member?(class_names, name)

  defp scalar?(_type, _class_names), do: false

  # A type that is (only) a dropped class.
  defp keep?(%{"name" => name}) when name in @dropped_classes, do: false
  defp keep?(_type), do: true
end
