defmodule Mix.PlaywrightEx.TestRegistry do
  @moduledoc """
  The upstream test registry and the tests we do not port, as playwright-python and
  playwright-java keep them (their `scripts/check_test_registry.py`).

    * `test/upstream_registry.md`: a copy of upstream's `tests/registry.md`, every test in
      `tests/page` and `tests/library` with its identifier (`CH-017`) and its title (describe
      titles and the test title without the identifier, joined with " › "; the copies of a test
      that a loop declares share one row).
    * `test/upstream_not_ported.txt`: one rule per line, a selector then the reason. A selector
      is a test identifier (`CH-017`), a subsystem code (`CG`) or an upstream file glob without
      `.spec.ts` (`library/unit/*`).

  Our mirrored tests are named as upstream's, which start with the identifier
  (`test "CH-017 should work"`): a test matches the row of its upstream file (`@upstream`) with
  that identifier. `PlaywrightEx.UpstreamCase` skips the tests a rule matches, and
  `mix playwright_ex.parity` checks the rules against the tests.
  """

  @registry "test/upstream_registry.md"
  @rules "test/upstream_not_ported.txt"

  @row ~r/^\| `(?<id>[A-Z]{2}-(?:[A-Z]{2,3}-)?\d{3})` \| `(?<file>[^`]+)` \| (?<title>.*?)(?: \*\((?<copies>\d+) copies\)\*)?(?: \| \d{4}-\d{2}-\d{2} \| `[0-9a-f]+`)? \|$/
  @subsystem ~r/^\| `(?<code>[A-Z]{2})` \| (?<name>[^|]+?) \|/
  @id ~r/^[A-Z]{2}-(?:[A-Z]{2,3}-)?\d{3}$/
  @name_id ~r/^([A-Z]{2}-(?:[A-Z]{2,3}-)?\d{3}) /
  @code ~r/^[A-Z]{2}$/

  def registry_path, do: @registry
  def rules_path, do: @rules

  @doc """
  Registry rows in file order, `%{id, code, file, title, copies}` (`file` without `tests/` and
  `.spec.ts`), and the subsystems, `[{code, name}]`.
  """
  def read_registry(path \\ @registry) do
    lines = path |> File.read!() |> String.split("\n")

    rows =
      for line <- lines, row = Regex.named_captures(@row, line) do
        %{
          id: row["id"],
          code: binary_part(row["id"], 0, 2),
          file: String.replace_suffix(row["file"], ".spec.ts", ""),
          title: unescape_markdown(row["title"]),
          copies: if(row["copies"] == "", do: 1, else: String.to_integer(row["copies"]))
        }
      end

    subsystems = for line <- lines, s = Regex.named_captures(@subsystem, line), do: {s["code"], String.trim(s["name"])}
    {rows, subsystems}
  end

  defp unescape_markdown(text), do: Regex.replace(~r/\\([\\`*_\[\]<>|])/, text, "\\1")

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
  The row of a test in `rows` (the rows of its file) with the test's identifier (`id/1`):
  `{:ok, row}`, or `:none`.
  """
  def match(rows, id) do
    case id && Enum.find(rows, &(&1.id == id)) do
      nil -> :none
      row -> {:ok, row}
    end
  end

  @doc """
  The identifier a test name starts with (`"CH-017 should work"`), or nil. `name` is a string,
  or the AST of a name built at runtime (its literal start).
  """
  def id(name) when is_binary(name) do
    case Regex.run(@name_id, name, capture: :all_but_first) do
      [id] -> id
      nil -> nil
    end
  end

  def id({:<<>>, _, [first | _]}), do: id(first)
  def id({:<>, _, [left, _]}), do: id(left)
  def id(_), do: nil

  @doc """
  The reason a rule gives for not porting the test (`upstream` spec path, `name`), or nil.
  Reads the registry and the rules once per VM (`root` holds `test/`).
  """
  def not_ported_reason(root, upstream, name) do
    {rows_by_file, rules} = cached(root)

    case match(Map.get(rows_by_file, file_key(upstream), []), id(name)) do
      {:ok, row} -> if rule = rule_for(row, rules), do: rule.reason
      :none -> nil
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
  order, each `%{name, id, describe, body?, line, skips, tag_skips, slow?}`. `name` is a string, or a regex for a
  name built at runtime; `id` its identifier (`id/1`); `describe` the title of its `describe`, nil
  without one, `:dynamic` when it is not known statically; `skips` the static `skip:` reasons of
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
      id: id(name),
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
