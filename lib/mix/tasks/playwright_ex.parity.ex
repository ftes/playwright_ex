defmodule Mix.Tasks.PlaywrightEx.Parity do
  @shortdoc "Compares ported modules and tests with their upstream sources"
  @moduledoc """
  Checks that every ported module still covers its upstream file, and every mirrored test
  module its upstream spec.

      mix playwright_ex.parity [--extra]

  Sources: `PlaywrightEx.Upstream.ensure!/0` (the pinned upstream release).

    * Completeness: every upstream client file (`packages/playwright-core/src/client/*.ts`) needs a
      module with `@upstream` for it (in `lib` or `test/support`), every spec
      (`tests/page/**/*.spec.ts`, `tests/library/**/*.spec.ts`) a test module with `@upstream`
      for it, unless listed with a reason in `@unported_client_files` / `@unmirrored_specs` in
      this module. An exclusion for a file that is not upstream, or that has a module after all,
      is stale. Review both lists on a version roll.
    * Modules with `@upstream "<path>.ts"` (nested modules inherit it): each upstream class
      maps to the module named after it (last alias segment), else to the module declaring
      `@upstream`; top-level functions map to that module too. An upstream method is
      covered when the module defines a function with its snake_case name, or when a line
      in the module's file containing "not ported" or "ported as" mentions it (or its class). Generated
      files are skipped. Ported methods must keep the upstream order: the module's functions and the
      names on its module-level marker lines (before the marker), in file order, compared with the
      upstream methods; names outside their longest common subsequence are out of order.
      Functions with no upstream name are ignored.
    * Test modules with `@upstream "tests/<path>.spec.ts"`: upstream test names (`it`,
      `test`, `browserTest`, ... including `.skip`/`.fixme`, flattened over `describe`) must
      equal the module's `test` names, compared as multisets, and come in the same order.
      Names built at runtime (template literals with `${`, concatenation) are not compared.
    * Skip reasons in `test/upstream` (`@tag`/`@describetag`/`@moduletag skip:`, including
      `<>`, `if`/`case`/`cond` branches and module attributes): a reason that only lists API
      names, `not ported: <name>[ (<note>)][, <name>...]` (also joined with `and`), says those
      are missing. A `Class.member` among them (outside parentheses) whose class module
      (`PlaywrightEx.Client.<Class>` or the facade `PlaywrightEx.<Class>`) exports the
      snake_case function is a stale skip. Any other wording is an explanation and is not
      checked: a reason citing a ported member that still cannot be used says what is missing
      in words (`not ported: Page.removeAllListeners behavior option`).

    * The generated facade (`mix playwright_ex.gen.api --check`): regenerating it from
      `api.json` must give the committed files. It has every member, so a client function it
      calls that is missing is a compile warning.

  Fails when anything is missing. `--extra` also lists public functions with no upstream
  counterpart (informational: Elixir-only helpers are expected).
  """
  use Mix.Task

  # Upstream names that have no Elixir function by convention (see PORTING.md).
  @by_convention ~w(constructor from fromNullable)
  # Elixir-side counterparts of the constructor and process plumbing, not reported by --extra.
  @not_extra ~w(new start_link child_spec init handle_call handle_cast handle_info terminate)

  # Upstream files with no module or test module on purpose, path => reason. Review on a version
  # roll: new upstream files show up as missing, removed or since-ported ones as stale.
  @unported_client_files %{
    "packages/playwright-core/src/client/android.ts" =>
      "not in the JS api.json at this pin (Connection maps Android* to DummyChannelOwner)",
    "packages/playwright-core/src/client/channels.d.ts" => "type-only (protocol channel types)",
    "packages/playwright-core/src/client/clientInstrumentation.ts" =>
      "instrumentation not ported (`not ported: instrumentation` markers at the call sites)",
    "packages/playwright-core/src/client/electron.ts" =>
      "not in the JS api.json at this pin (Connection maps Electron* to DummyChannelOwner)",
    "packages/playwright-core/src/client/types.ts" => "type-only"
  }

  codegen = "inspector codegen/recorder UI (Node-only tooling)"
  launch_server = "BrowserType.launchServer (out of scope, see PLAN.md)"
  injected = "injected script internals (driver side, not the client)"

  @unmirrored_specs %{
    "tests/library/browser-server.spec.ts" => launch_server,
    "tests/library/browsertype-launch-server.spec.ts" => launch_server,
    "tests/library/component-parser.spec.ts" => "isomorphic component parser (test-runner tooling)",
    "tests/library/css-parser.spec.ts" => "isomorphic CSS selector parser (driver side)",
    "tests/library/debug-controller.spec.ts" => "debug controller (driver-side tooling protocol)",
    "tests/library/inspector/cli-codegen-1.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-2.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-3.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-aria.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-csharp.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-java.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-javascript.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-pick-locator.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-pytest.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-python-async.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-python.spec.ts" => codegen,
    "tests/library/inspector/cli-codegen-test.spec.ts" => codegen,
    "tests/library/inspector/console-api.spec.ts" => codegen,
    "tests/library/inspector/pause.spec.ts" => codegen,
    "tests/library/inspector/recorder-api.spec.ts" => codegen,
    "tests/library/inspector/title.spec.ts" => codegen,
    # Revisit with PLAN "Then" item 4 (Elixir locator rendering), or when locatorGenerators /
    # locatorParser are ported.
    "tests/library/locator-generator.spec.ts" => "isomorphic locator generators (not ported)",
    "tests/library/locator-parser.spec.ts" => "isomorphic locator parser (not ported)",
    "tests/library/role-utils.spec.ts" => injected,
    "tests/library/selector-generator.spec.ts" => injected,
    "tests/library/snapshot-renderer.spec.ts" => "trace snapshot renderer (trace viewer internals)",
    "tests/library/trace-viewer.spec.ts" => "trace viewer UI (Node-only tooling)",
    "tests/library/unit/android-webviews.spec.ts" => "server internals (Android)",
    "tests/library/unit/clock.spec.ts" => "injected clock internals (driver side)",
    "tests/library/unit/codegen.spec.ts" => "trace viewer codegen (Node-only tooling)",
    "tests/library/unit/json-schema.spec.ts" => "isomorphic JSON schema validator (driver side)",
    "tests/library/unit/sequence.spec.ts" => "server internals",
    "tests/page/expect-builtins.spec.ts" => "jest generic matchers (test runner, see PLAN.md)",
    "tests/page/matchers.misc.spec.ts" => "jest generic matchers (test runner, see PLAN.md)"
  }

  @impl true
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [extra: :boolean])
    upstream = PlaywrightEx.Upstream.ensure!()
    Mix.Task.run("compile")

    lib_modules =
      Enum.flat_map(Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/support/**/*.ex"), &elixir_modules/1)

    test_modules = Enum.flat_map(Path.wildcard("test/**/*_test.exs"), &elixir_modules/1)

    problems =
      check_files(
        upstream_files(upstream, ["packages/playwright-core/src/client/*.ts"]),
        claimed(lib_modules),
        @unported_client_files,
        "no module with `@upstream` for it (port it or list it in @unported_client_files)"
      ) ++
        check_files(
          upstream_files(upstream, ["tests/page/**/*.spec.ts", "tests/library/**/*.spec.ts"]),
          claimed(test_modules),
          @unmirrored_specs,
          "no test module with `@upstream` for it (mirror it or list it in @unmirrored_specs)"
        ) ++
        check_modules(upstream, lib_modules, opts[:extra]) ++
        check_tests(upstream, test_modules) ++
        check_skips(Path.wildcard("test/upstream/**/*_test.exs"), &ported?/2) ++
        check_facade(upstream)

    if problems == [] do
      Mix.shell().info("parity: ok")
    else
      Enum.each(problems, fn problem -> Mix.shell().info(problem) end)
      Mix.raise("parity: #{length(problems)} problem(s)")
    end
  end

  # --- upstream files --------------------------------------------------------

  defp upstream_files(upstream, patterns) do
    for pattern <- patterns, path <- Path.wildcard(Path.join(upstream, pattern)), uniq: true do
      Path.relative_to(path, upstream)
    end
  end

  defp claimed(modules), do: for(%{upstream: path} when is_binary(path) <- modules, into: MapSet.new(), do: path)

  @doc false
  # Problems for upstream `files` that no module claims and `exclusions` (path => reason) does
  # not list, and for exclusions that are stale: not upstream, or claimed after all.
  def check_files(files, claimed, exclusions, missing_message) do
    unclaimed =
      for file <- Enum.sort(files),
          file not in claimed,
          not Map.has_key?(exclusions, file),
          do: "#{file}: #{missing_message}"

    stale =
      for {file, _reason} <- Enum.sort(exclusions) do
        cond do
          file not in files -> "#{file}: excluded but not found upstream, drop the exclusion"
          file in claimed -> "#{file}: excluded but has a module with `@upstream` for it, drop the exclusion"
          true -> nil
        end
      end

    unclaimed ++ Enum.reject(stale, &is_nil/1)
  end

  # --- facade ----------------------------------------------------------------

  defp check_facade(upstream) do
    for path <- Mix.Tasks.PlaywrightEx.Gen.Api.check(upstream),
        do: "#{path}: out of date with api.json, run mix playwright_ex.gen.api"
  end

  # --- modules ---------------------------------------------------------------

  defp check_modules(upstream, modules, extra?) do
    modules
    |> Enum.filter(&(&1.upstream && String.ends_with?(&1.upstream, ".ts") && !&1.generated))
    |> Enum.group_by(& &1.upstream)
    |> Enum.sort()
    |> Enum.flat_map(fn {ts_path, mods} -> check_module_file(upstream, ts_path, mods, extra?) end)
  end

  defp check_module_file(upstream, ts_path, mods, extra?) do
    source = Path.join(upstream, ts_path)

    if File.regular?(source) do
      ts = ts_members(File.read!(source))
      if extra?, do: report_extra(ts_path, ts, mods)
      missing(ts_path, ts, mods) ++ out_of_order(ts_path, ts, mods)
    else
      ["#{ts_path}: not found upstream (referenced by #{inspect(hd(mods).name)})"]
    end
  end

  defp missing(ts_path, ts, mods) do
    root = root_module(ts_path, mods)
    acknowledged = mods |> Enum.map(& &1.file) |> Enum.uniq() |> Enum.flat_map(&acknowledged/1) |> MapSet.new()
    by_module = Enum.group_by(ts, fn {class, _} -> module_for(class, mods, root) end, fn {_, m} -> m end)

    {rootless, by_module} = Map.pop(by_module, nil, [])

    no_root =
      if rootless != [],
        do: [
          "#{ts_path}: no module for #{Enum.map_join(Enum.uniq(rootless), ", ", &underscore/1)} " <>
            "(top-level functions and classes without a module go to the root module, named after the file)"
        ],
        else: []

    no_root ++
      for {mod, names} <- Enum.sort_by(by_module, &inspect(elem(&1, 0).name)),
          classes = for({c, _} <- ts, module_for(c, mods, root) == mod, c, do: c),
          missing = Enum.reject(Enum.uniq(names), &(&1 in @by_convention or covered?(&1, mod, acknowledged, classes))),
          missing != [] do
        "#{ts_path}: #{inspect(mod.name)} is missing #{Enum.map_join(missing, ", ", &underscore/1)}"
      end
  end

  defp out_of_order(ts_path, ts, mods) do
    root = root_module(ts_path, mods)

    for mod <- mods,
        upstream_names = for({c, m} <- ts, module_for(c, mods, root) == mod, uniq: true, do: m),
        to_upstream = Map.new(Enum.flat_map(upstream_names, &[{underscore(&1), &1}, {&1, &1}])),
        ported = for(name <- ported_in_order(mod), Map.has_key?(to_upstream, name), uniq: true, do: to_upstream[name]),
        wrong = unordered(upstream_names, ported),
        wrong != [] do
      "#{ts_path}: #{inspect(mod.name)} is out of upstream order at #{Enum.map_join(wrong, ", ", &underscore/1)}"
    end
  end

  # Function names and names on module-level marker lines (before the marker), in file order.
  @doc false
  def ported_in_order(mod) do
    markers =
      for {line, n} <- mod.file |> File.stream!() |> Stream.with_index(1),
          n in mod.lines,
          [indent, comment] <- [Regex.run(~r/^(\s*)#(.*)/, line, capture: :all_but_first) || []],
          String.length(indent) == mod.def_indent,
          [before, _ | _] <- [Regex.split(~r/--|not ported|ported as/i, comment)],
          [word] <- Regex.scan(~r/[A-Za-z_$][\w$]*/, before),
          do: {n, word}

    (mod.defs ++ markers) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  # Elements of `actual` that are not in its longest common subsequence with `expected`.
  @doc false
  def unordered(expected, actual) do
    expected = Enum.filter(expected, &(&1 in actual))
    actual = Enum.filter(actual, &(&1 in expected))
    actual -- lcs(expected, actual)
  end

  # Longest common subsequence, row by row: each cell holds {length, reversed subsequence}.
  defp lcs(a, b) do
    first_row = List.duplicate({0, []}, length(b) + 1)

    a
    |> Enum.reduce(first_row, &lcs_row(&1, b, &2))
    |> List.last()
    |> elem(1)
    |> Enum.reverse()
  end

  defp lcs_row(x, b, prev) do
    row =
      Enum.scan(Enum.zip([b, prev, tl(prev)]), {0, []}, fn {y, {n, diag}, up}, left ->
        if x == y, do: {n + 1, [x | diag]}, else: Enum.max_by([up, left], &elem(&1, 0))
      end)

    [{0, []} | row]
  end

  defp report_extra(ts_path, ts, mods) do
    upstream_names = MapSet.new(ts, fn {_, m} -> underscore(m) end)
    ignored? = &(&1 in upstream_names or &1 in @not_extra or String.starts_with?(&1, "__"))

    for mod <- mods, extra = Enum.reject(mod.public, ignored?), extra != [] do
      Mix.shell().info("#{ts_path}: #{inspect(mod.name)} has no upstream method for #{Enum.join(extra, ", ")}")
    end
  end

  # The module of a file's top-level functions (and of its classes without a module of their own):
  # the only module declaring `@upstream` for it, else the one named after the file
  # (`network.ts` is `Client.Network`, not `Client.Request`), else none.
  @doc false
  def root_module(ts_path, mods) do
    case Enum.filter(mods, & &1.declares_upstream) do
      [one] -> one
      declaring -> Enum.find(declaring, &(last_segment(&1) == ts_path |> Path.basename(".ts") |> Macro.camelize()))
    end
  end

  defp last_segment(mod), do: mod.name |> Module.split() |> List.last()

  defp module_for(nil, _mods, root), do: root

  defp module_for(class, mods, root) do
    Enum.find(mods, root, &(last_segment(&1) == class))
  end

  defp covered?(name, mod, acknowledged, classes) do
    underscore(name) in mod.functions or name in acknowledged or underscore(name) in acknowledged or
      Enum.any?(classes, &(&1 in acknowledged))
  end

  defp underscore(name), do: Macro.underscore(name)

  # Identifiers on any line of the file that says "not ported" or "ported as".
  defp acknowledged(file) do
    for line <- File.stream!(file),
        String.contains?(String.downcase(line), ["not ported", "ported as"]),
        [word] <- Regex.scan(~r/[A-Za-z_$][\w$]*/, line),
        do: word
  end

  @ts_class ~r/^(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(\w+)/
  @ts_method ~r/^  (?:(?:private|protected|public|static|async|override|readonly)\s+)*(?:(?:get|set)\s+(?=[\w$]+\s*\())?([A-Za-z_$][\w$]*)\s*(?:<[^()]*>)?\(/
  @ts_function ~r/^(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/

  @doc false
  # [{class | nil, name}] in source order, for class methods and top-level functions.
  def ts_members(source) do
    source
    |> String.split("\n")
    |> Enum.reduce({nil, []}, fn line, {class, acc} ->
      case ts_line(line, class) do
        {:class, name} -> {name, acc}
        :class_end -> {nil, acc}
        {:member, name} -> {class, [{class, name} | acc]}
        nil -> {class, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp ts_line(line, class) do
    cond do
      match = Regex.run(@ts_class, line) -> {:class, Enum.at(match, 1)}
      class && String.starts_with?(line, "}") -> :class_end
      match = Regex.run(if(class, do: @ts_method, else: @ts_function), line) -> {:member, Enum.at(match, 1)}
      true -> nil
    end
  end

  # --- Elixir sources --------------------------------------------------------

  @doc false
  # Modules in `file`, with their effective `@upstream`, and the functions defined directly in them.
  def elixir_modules(file) do
    source = File.read!(file)
    generated = String.starts_with?(source, "# This file is generated")
    ast = Code.string_to_quoted!(source, file: file, columns: true, token_metadata: true)
    collect(ast, nil, nil, %{file: file, generated: generated})
  end

  defp collect({:defmodule, meta, [{:__aliases__, _, alias}, [do: body]]}, parent, inherited, info) do
    name = if parent, do: Module.concat([parent | alias]), else: Module.concat(alias)
    exprs = block(body)
    own = Enum.find_value(exprs, &upstream_attr/1)

    defs =
      for {kind, meta, [head | _]} <- exprs, kind in [:def, :defp, :defmacro, :defmacrop, :defdelegate] do
        {kind in [:def, :defmacro, :defdelegate], fun_name(head), meta[:line]}
      end

    module =
      Map.merge(info, %{
        name: name,
        upstream: own || inherited,
        declares_upstream: own != nil,
        functions: for({_, n, _} <- defs, uniq: true, do: n),
        public: for({true, n, _} <- defs, uniq: true, do: n),
        defs: for({_, n, line} <- defs, do: {line, n}),
        lines: meta[:line]..meta[:end][:line],
        def_indent: meta[:column] + 1,
        tests: test_names(body)
      })

    [module | Enum.flat_map(exprs, &collect(&1, name, own || inherited, info))]
  end

  defp collect({:__block__, _, exprs}, parent, inherited, info),
    do: Enum.flat_map(exprs, &collect(&1, parent, inherited, info))

  defp collect(_, _, _, _), do: []

  defp block({:__block__, _, exprs}), do: exprs
  defp block(expr), do: [expr]

  defp upstream_attr({:@, _, [{:upstream, _, [path]}]}) when is_binary(path), do: path
  defp upstream_attr(_), do: nil

  defp fun_name({:when, _, [head | _]}), do: fun_name(head)
  defp fun_name({name, _, _}) when is_atom(name), do: Atom.to_string(name)

  # `test "name"` anywhere below (inside `describe`), not in nested modules.
  defp test_names(body) do
    body
    |> Macro.prewalk([], fn
      {:defmodule, _, _}, acc -> {nil, acc}
      {:test, _, [name | _]} = node, acc when is_binary(name) -> {node, [name | acc]}
      node, acc -> {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # --- tests -----------------------------------------------------------------

  defp check_tests(upstream, modules) do
    modules
    |> Enum.filter(&(&1.upstream && String.ends_with?(&1.upstream, ".spec.ts")))
    |> Enum.sort_by(& &1.upstream)
    |> Enum.flat_map(fn mod ->
      source = Path.join(upstream, mod.upstream)

      if File.regular?(source) do
        expected = spec_tests(File.read!(source))
        {missing, extra} = multiset_diff(expected, mod.tests)

        Enum.map(missing, &"#{mod.upstream}: missing test #{inspect(&1)}") ++
          Enum.map(extra, &"#{mod.upstream}: test #{inspect(&1)} is not upstream") ++
          Enum.map(unordered(expected, mod.tests), &"#{mod.upstream}: test #{inspect(&1)} is out of upstream order")
      else
        ["#{mod.upstream}: not found upstream (referenced by #{inspect(mod.name)})"]
      end
    end)
  end

  @spec_test ~r/^\s*(?:it|test|browserTest|playwrightTest|contextTest|pageTest)(?:\.(?:skip|fixme|fail|only|slow))?\(\s*(?:'((?:\\.|[^'\\])*)'|"((?:\\.|[^"\\])*)"|`((?:\\.|[^`\\])*)`)\s*([,)])?/m

  @doc false
  # Statically known test names in a spec file.
  def spec_tests(source) do
    for match <- Regex.scan(@spec_test, source, capture: :all_but_first),
        [single, double, template, next] = pad(match, 4),
        next != "",
        name = single <> double <> template,
        not String.contains?(template, "${"),
        do: unescape(name)
  end

  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))

  defp unescape(name), do: Regex.replace(~r/\\(.)/, name, "\\1")

  defp multiset_diff(expected, actual) do
    {Enum.sort(expected -- actual), Enum.sort(actual -- expected)}
  end

  # --- skip reasons ----------------------------------------------------------

  @doc false
  # "stale skip" problems for `not ported:` reasons citing members that `ported?.(class, member)`.
  def check_skips(files, ported?) do
    for file <- Enum.sort(files),
        {line, reason} <- skip_reasons(File.read!(file)),
        {class, member} <- cited_members(reason),
        ported?.(class, member) do
      "stale skip: #{file}:#{line} cites #{class}.#{member}, which is ported"
    end
  end

  @doc false
  # [{line, reason}] for `@tag`/`@describetag`/`@moduletag skip: <expr>`. The reasons are the
  # static strings `<expr>` can evaluate to (literals, `<>`, `if`/`unless`/`case`/`cond`
  # branches, module attributes set to those).
  def skip_reasons(source) do
    ast = Code.string_to_quoted!(source)

    {_, attrs} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, attrs when is_atom(name) ->
          {node, Map.put(attrs, name, value)}

        node, attrs ->
          {node, attrs}
      end)

    {_, reasons} =
      Macro.prewalk(ast, [], fn
        {:@, meta, [{tag, _, [opts]}]} = node, acc when tag in [:tag, :describetag, :moduletag] and is_list(opts) ->
          reasons = if Keyword.keyword?(opts), do: static_strings(opts[:skip], attrs), else: []
          {node, Enum.reverse(Enum.map(reasons, &{meta[:line], &1}), acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(reasons)
  end

  defp static_strings(string, _attrs) when is_binary(string), do: [string]

  defp static_strings({:<>, _, [left, right]}, attrs),
    do: for(l <- static_strings(left, attrs), r <- static_strings(right, attrs), do: l <> r)

  defp static_strings({op, _, [_, branches]}, attrs) when op in [:if, :unless] and is_list(branches),
    do: Enum.flat_map(branches, fn {_, expr} -> static_strings(expr, attrs) end)

  defp static_strings({:case, _, [_, [do: clauses]]}, attrs), do: clause_strings(clauses, attrs)
  defp static_strings({:cond, _, [[do: clauses]]}, attrs), do: clause_strings(clauses, attrs)
  defp static_strings({:__block__, _, [expr]}, attrs), do: static_strings(expr, attrs)

  defp static_strings({:@, _, [{name, _, ctx}]}, attrs) when is_atom(ctx) and is_map_key(attrs, name) do
    {value, attrs} = Map.pop(attrs, name)
    static_strings(value, attrs)
  end

  defp static_strings(_, _attrs), do: []

  defp clause_strings(clauses, attrs),
    do: Enum.flat_map(clauses, fn {:->, _, [_, body]} -> static_strings(body, attrs) end)

  @api_name ~S"[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*(?:\s*\([^()]*\))?"
  @api_list Regex.compile!("^not ported: #{@api_name}(?:(?:,\\s*|\\s+and\\s+)#{@api_name})*$")

  @doc false
  # The `{Class, member}`s a reason says are missing: only a reason that is a list of API names
  # (each optionally followed by one parenthetical) cites them, and only outside parentheses.
  def cited_members(reason) do
    reason = String.trim(reason)

    if Regex.match?(@api_list, reason) do
      reason = Regex.replace(~r/\([^()]*\)/, reason, "")
      for [_, class, member] <- Regex.scan(~r/\b([A-Z][\w$]*)\.([A-Za-z_$][\w$]*)/, reason), do: {class, member}
    else
      []
    end
  end

  @doc false
  # Whether the client class or its facade module exports the member's snake_case function.
  def ported?(class, member) do
    name = underscore(member)

    Enum.any?([PlaywrightEx.Client, PlaywrightEx], fn namespace ->
      module = Module.concat(namespace, class)

      Code.ensure_loaded?(module) and
        Enum.any?(module.__info__(:functions), fn {fun, _} -> Atom.to_string(fun) == name end)
    end)
  end
end
