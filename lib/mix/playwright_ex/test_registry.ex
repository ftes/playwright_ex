defmodule Mix.PlaywrightEx.TestRegistry do
  @moduledoc """
  The upstream test registry and the tests we do not port, as playwright-python and
  playwright-java keep them (their `scripts/check_test_registry.py`).

    * `test/upstream_registry.md`: a copy of upstream's `tests/registry.md`, every test in
      `tests/page` and `tests/library` with its identifier (`CH-017`) and its title (describe
      titles and the test title, joined with " › "; the `{a, b}` variants of a test that a loop
      declares share one row).
    * `test/upstream_not_ported.txt`: one rule per line, a selector then the reason. A selector
      is a test identifier (`CH-017`), a subsystem code (`CG`) or an upstream file glob without
      `.spec.ts` (`library/unit/*`).

  Our mirrored tests carry no identifier: a test matches a row by its upstream file (`@upstream`)
  and its name, which is the upstream title (the last segment). Several rows with that title in
  one file are told apart by the test's `describe`: the row's describe titles joined with a
  space, or one of them. `PlaywrightEx.UpstreamCase` skips the tests a rule matches, and
  `mix playwright_ex.parity` checks the rules against the tests.
  """

  @registry "test/upstream_registry.md"
  @rules "test/upstream_not_ported.txt"

  @row ~r/^\| `(?<id>[A-Z]{2}-(?:[A-Z]{2,3}-)?\d{3})` \| `(?<file>[^`]+)` \| (?<title>.*?)(?: \*\((?<copies>\d+) copies\)\*)?(?: \| \d{4}-\d{2}-\d{2} \| `[0-9a-f]+`)? \|$/
  @subsystem ~r/^\| `(?<code>[A-Z]{2})` \| (?<name>[^|]+?) \|/
  @id ~r/^[A-Z]{2}-(?:[A-Z]{2,3}-)?\d{3}$/
  @code ~r/^[A-Z]{2}$/

  def registry_path, do: @registry
  def rules_path, do: @rules

  @doc """
  Registry rows in file order, `%{id, code, file, title, copies, variants}` (`file` without
  `tests/` and `.spec.ts`; `variants` the `{describe_titles, title}` of each copy), and the
  subsystems, `[{code, name}]`.
  """
  def read_registry(path \\ @registry) do
    lines = path |> File.read!() |> String.split("\n")

    rows =
      for line <- lines, row = Regex.named_captures(@row, line) do
        title = unescape_markdown(row["title"])
        copies = if row["copies"] == "", do: 1, else: String.to_integer(row["copies"])

        %{
          id: row["id"],
          code: binary_part(row["id"], 0, 2),
          file: String.replace_suffix(row["file"], ".spec.ts", ""),
          title: title,
          copies: copies,
          variants: variants(title, copies)
        }
      end

    subsystems = for line <- lines, s = Regex.named_captures(@subsystem, line), do: {s["code"], String.trim(s["name"])}
    {rows, subsystems}
  end

  defp unescape_markdown(text), do: Regex.replace(~r/\\([\\`*_\[\]<>|])/, text, "\\1")

  # A loop's copies share a row whose title spells the variants as `{a, b}`.
  defp variants(title, copies) do
    titles = if copies > 1, do: expand(title), else: [title]

    for title <- Enum.uniq(titles) do
      {describes, [leaf]} = title |> String.split(" › ") |> Enum.split(-1)
      {describes, leaf}
    end
  end

  defp expand(title) do
    case Regex.run(~r/\{([^{}]*)\}/, title, return: :index) do
      [{start, length}, {inner_start, inner_length}] ->
        prefix = binary_part(title, 0, start)
        suffix = binary_part(title, start + length, byte_size(title) - start - length)

        for alt <- String.split(binary_part(title, inner_start, inner_length), ", "),
            rest <- expand(suffix),
            do: prefix <> alt <> rest

      nil ->
        [title]
    end
  end

  @doc "Rules in file order, `%{line, selector, reason}`, and the problems of lines that are none."
  def read_rules(path \\ @rules) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {line, n}, {rules, problems} ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          {rules, problems}

        match?([_, _], parts = String.split(line, ~r/\s+/, parts: 2)) ->
          [selector, reason] = parts
          {[%{line: n, selector: selector, reason: reason} | rules], problems}

        true ->
          {rules, ["#{Path.basename(path)}:#{n}: the rule has no reason" | problems]}
      end
    end)
    |> then(fn {rules, problems} -> {Enum.reverse(rules), Enum.reverse(problems)} end)
  end

  @doc "Whether `rule` selects `row`."
  def matches?(%{selector: selector}, row) do
    cond do
      Regex.match?(@id, selector) -> row.id == selector
      Regex.match?(@code, selector) -> row.code == selector
      true -> glob_match?(selector, row.file)
    end
  end

  # fnmatch: `*` and `?` also match `/`.
  defp glob_match?(glob, file) do
    regex =
      glob
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(~r/^#{regex}$/, file)
  end

  @doc "The first rule that selects `row`, or nil."
  def rule_for(row, rules), do: Enum.find(rules, &matches?(&1, row))

  @doc "The registry file key of an `@upstream` spec path (`tests/page/page-check.spec.ts`)."
  def file_key(upstream), do: upstream |> String.replace_prefix("tests/", "") |> String.replace_suffix(".spec.ts", "")

  @doc """
  The row of a test in `rows` (the rows of its file): `{:ok, row}`, `:none`, or
  `{:ambiguous, rows}`. `describe` is the test's describe, nil without one, `:dynamic` when
  it is not known statically. A name pattern (a test declared in a loop) matches
  `{:pattern, rows}`.
  """
  def match(rows, _describe, %Regex{} = name) do
    case Enum.filter(rows, fn row -> Enum.any?(row.variants, &Regex.match?(name, elem(&1, 1))) end) do
      [] -> :none
      rows -> {:pattern, rows}
    end
  end

  def match(rows, describe, name) do
    case Enum.filter(rows, fn row -> Enum.any?(row.variants, &(elem(&1, 1) == name)) end) do
      [] ->
        :none

      [row] ->
        {:ok, row}

      candidates ->
        by_describe(candidates, describe, name)
    end
  end

  # The describe titles joined, else one of them.
  defp by_describe(candidates, describe, name) do
    exact = Enum.filter(candidates, &describe_matches?(&1, describe, name, :exact))

    case if(exact == [], do: Enum.filter(candidates, &describe_matches?(&1, describe, name, :any)), else: exact) do
      [row] -> {:ok, row}
      _ -> {:ambiguous, candidates}
    end
  end

  defp describe_matches?(_row, :dynamic, _name, _how), do: false

  defp describe_matches?(row, describe, name, how) do
    Enum.any?(row.variants, fn {describes, leaf} ->
      leaf == name and
        cond do
          describe in [nil, ""] -> describes == []
          how == :exact -> describe == Enum.join(describes, " ")
          true -> describe in describes
        end
    end)
  end

  @doc """
  The reason a rule gives for not porting the test (`upstream` spec path, `describe`, `name`),
  or nil. Reads the registry and the rules once per VM (`root` holds `test/`).
  """
  def not_ported_reason(root, upstream, describe, name) do
    {rows_by_file, rules} = cached(root)
    rows = Map.get(rows_by_file, file_key(upstream), [])

    candidates =
      case match(rows, describe, name) do
        {:ok, row} -> [row]
        # All candidates under one rule (a file or subsystem rule): no matter which.
        {:ambiguous, candidates} -> candidates
        _ -> []
      end

    case Enum.uniq_by(candidates, &rule_for(&1, rules)) do
      [row] -> if rule = rule_for(row, rules), do: rule.reason
      _ -> nil
    end
  end

  defp cached(root) do
    key = {__MODULE__, root}

    case :persistent_term.get(key, nil) do
      nil ->
        {rows, _} = read_registry(Path.join(root, @registry))
        {rules, _} = read_rules(Path.join(root, @rules))
        value = {Enum.group_by(rows, & &1.file), rules}
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  @doc """
  The test modules in a source that declare `@upstream`: `[{upstream, tests}]`, the tests in
  order, each `%{name, describe, body?, line, skips, tag_skips, slow?}`. `name` is a string, or a regex for a
  name built at runtime; `describe` as in `match/3`; `skips` the static `skip:` reasons of
  the test's `@tag`s, its `@describetag`s and the module's `@moduletag`s (those that are
  string literals, also joined with `<>`; conditional ones are not static); `tag_skips` those
  of its own `@tag`s; `slow?` whether a `timeout:` of its `@tag`s, `@describetag`s or the module's
  `@moduletag`s (also under an `if`) uses `@slow_timeout` (`test.slow()`).
  """
  def test_modules(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:defmodule, _, [_, [do: body]]} = node, acc -> {node, test_module(block(body)) ++ acc}
      node, acc -> {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp test_module(exprs) do
    case for({:@, _, [{:upstream, _, [path]}]} when is_binary(path) <- exprs, do: path) do
      [upstream | _] ->
        scope = %{
          describe: nil,
          skips: static_skips(exprs, :moduletag),
          slow?: Enum.any?(exprs, &slow?(&1, :moduletag))
        }

        [{upstream, walk(exprs, scope, [])}]

      [] ->
        []
    end
  end

  defp static_skips(exprs, attr),
    do: for({:@, _, [{^attr, _, [opts]}]} <- exprs, reason = static_skip(opts), do: reason)

  defp block({:__block__, _, exprs}), do: exprs
  defp block(expr), do: [expr]

  # The tests in `exprs`, in order; `@tag`s apply to the next test.
  defp walk(exprs, scope, tags) do
    exprs
    |> Enum.reduce({[], tags}, fn expr, {tests, tags} -> walk_expr(expr, scope, tests, tags) end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp walk_expr({:@, _, [{:tag, _, [opts]}]} = expr, _scope, tests, tags) do
    tags = if slow?(expr, :tag), do: [:slow | tags], else: tags
    {tests, if(reason = static_skip(opts), do: [reason | tags], else: tags)}
  end

  defp walk_expr({:test, meta, [name | rest]}, scope, tests, tags) do
    test = %{
      name: name(name),
      describe: scope.describe,
      body?: rest != [],
      line: meta[:line],
      skips: Enum.filter(tags, &is_binary/1) ++ scope.skips,
      tag_skips: Enum.filter(tags, &is_binary/1),
      slow?: :slow in tags or scope.slow?
    }

    {[test | tests], []}
  end

  defp walk_expr({:describe, _, [name, [do: body]]}, scope, tests, _tags) do
    exprs = block(body)
    describe = if is_binary(name), do: name, else: :dynamic

    scope = %{
      describe: describe,
      skips: static_skips(exprs, :describetag) ++ scope.skips,
      slow?: scope.slow? or Enum.any?(exprs, &slow?(&1, :describetag))
    }

    {Enum.reverse(walk(exprs, scope, []), tests), []}
  end

  defp walk_expr({:for, _, args}, scope, tests, tags),
    do: {Enum.reverse(walk(block(List.last(args)[:do]), scope, tags), tests), []}

  defp walk_expr({:__block__, _, exprs}, scope, tests, tags), do: {Enum.reverse(walk(exprs, scope, tags), tests), []}
  defp walk_expr(_expr, _scope, tests, tags), do: {tests, tags}

  # `@attr timeout: ... @slow_timeout ...` in `expr` (also under an `if`).
  defp slow?(expr, attr) do
    expr
    |> Macro.prewalk(false, fn
      {:@, _, [{^attr, _, [opts]}]} = node, acc when is_list(opts) ->
        {node, acc or (Keyword.keyword?(opts) and uses_slow_timeout?(opts[:timeout]))}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp uses_slow_timeout?(ast) do
    ast
    |> Macro.prewalk(false, fn node, acc -> {node, acc or match?({:@, _, [{:slow_timeout, _, _}]}, node)} end)
    |> elem(1)
  end

  defp static_skip(opts) when is_list(opts), do: if(Keyword.keyword?(opts), do: static_string(opts[:skip]))
  defp static_skip(_), do: nil

  defp static_string(string) when is_binary(string), do: string

  defp static_string({:<>, _, [left, right]}) do
    with l when is_binary(l) <- static_string(left), r when is_binary(r) <- static_string(right), do: l <> r
  end

  defp static_string(_), do: nil

  # A name built at runtime (interpolation, `<>`) is a pattern: its literal parts, anything between.
  defp name(name) when is_binary(name), do: name
  defp name(name), do: ~r/^#{name |> name_parts() |> Enum.join()}$/

  defp name_parts(part) when is_binary(part), do: [Regex.escape(part)]
  defp name_parts({:<<>>, _, parts}), do: Enum.flat_map(parts, &name_parts/1)
  defp name_parts({:<>, _, [left, right]}), do: name_parts(left) ++ name_parts(right)
  defp name_parts(_), do: [".*"]
end
