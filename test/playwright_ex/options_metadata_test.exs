defmodule PlaywrightEx.OptionsMetadataTest do
  # `__options__/1` of the generated facade agrees with the `<member>_options` types and the
  # `## Options` bullets of the docs.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Locator

  @modules for path <- Path.wildcard("lib/playwright_ex/api/*.ex"),
               [_, name] <- [Regex.run(~r/^defmodule (\S+) do/m, File.read!(path))],
               do: Module.concat([name])

  test "an option's doc, type and since" do
    assert [{:button, button} | _] = Locator.__options__(:click)
    assert %{type_doc: "`:left` | `:right` | `:middle`", doc: "Defaults to `:left`.", since: nil} = button
    assert Macro.to_string(button.spec) == ":left | :right | :middle"

    assert {_, %{since: "1.62", doc: doc}} =
             List.keyfind(PlaywrightEx.WebSocket.__options__(:wait_for_event), :signal, 0)

    assert doc =~ ~r/^Allows to cancel/
  end

  test "an admonition is no doc: the paragraph after it" do
    assert {_, %{doc: "Additional arguments to pass to the browser instance." <> _}} =
             List.keyfind(PlaywrightEx.BrowserType.__options__(:launch), :args, 0)
  end

  test "a doc paragraph is one line, a list keeps its lines" do
    multiline =
      for module <- @modules,
          {member, _types} <- option_types(module),
          {key, %{doc: doc}} <- module.__options__(member),
          doc =~ "\n" and not (doc =~ ~r/^[*-] /),
          do: "#{inspect(module)}.#{member} #{inspect(key)}"

    assert multiline == []

    assert {_, %{doc: "* If set to " <> _ = list}} =
             List.keyfind(PlaywrightEx.Page.__options__(:route_from_har), :not_found, 0)

    assert list =~ "\n* "
  end

  test "a function without options has no clause" do
    # Not a literal: the type checker knows the clauses.
    member = String.to_atom("count")
    assert_raise FunctionClauseError, fn -> Locator.__options__(member) end
  end

  test "the options and specs of every `<member>_options` type" do
    mismatches =
      for module <- @modules,
          {member, types} <- option_types(module),
          options = module.__options__(member),
          Keyword.keys(options) != Keyword.keys(types) or
            Enum.any?(options, fn {key, meta} -> as_compiled(meta.spec, module) != types[key] end),
          do: "#{inspect(module)}.__options__(#{inspect(member)})"

    assert mismatches == []
  end

  test "the `## Options` bullets of the docs" do
    missing =
      for module <- @modules,
          {member, _types} <- option_types(module),
          doc <- [options_doc(module, member)],
          {key, meta} <- module.__options__(member),
          not bullet?(doc, key, meta),
          do: "#{inspect(module)}.#{member} #{inspect(key)}"

    assert missing == []
  end

  # "* `:key` (type) - *Since Playwright 1.62.* doc": the doc follows the head, after an
  # admonition or a blank line if it starts with a block, before the next option's bullet.
  # Whitespace is collapsed (bullets wrap).
  defp bullet?(doc, key, meta) do
    head = squish("* `#{inspect(key)}` (#{meta.type_doc})")
    since = if meta.since, do: "*Since Playwright #{meta.since}.* ", else: ""

    case String.split(doc, head, parts: 2) do
      [_, rest] -> rest |> String.split("* `:", parts: 2) |> hd() |> String.contains?(squish(since <> meta.doc))
      [_] -> false
    end
  end

  # The doc of the function documenting the member's options (not its bang form), "" if none does.
  defp options_doc(module, member) do
    {:docs_v1, _, _, _, _, _, entries} = Code.fetch_docs(module)

    Enum.find_value(entries, "", fn
      {{:function, ^member, _}, _, _, %{"en" => doc}, _} -> if doc =~ "## Options", do: squish(doc)
      _ -> nil
    end)
  end

  defp squish(text), do: String.replace(text, ~r/\s+/, " ")

  # A spec as the compiler keeps it in `module`: its own types local (`t()`), required map keys
  # bare (`:file => ...`).
  defp as_compiled(spec, module) do
    spec
    |> Macro.prewalk(fn
      {{:., _, [{:__aliases__, _, parts}, name]}, _, args} = call ->
        if Module.concat(parts) == module, do: {name, [], args}, else: call

      {:required, _, [key]} ->
        key

      node ->
        node
    end)
    |> Macro.to_string()
  end

  # %{member => [{key, spec}]}: the keyword list of each `<member>_options` type.
  defp option_types(module) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    for {:type, {type, ast, []}} <- types,
        name = Atom.to_string(type),
        String.ends_with?(name, "_options"),
        into: %{},
        do: {String.to_existing_atom(String.trim_trailing(name, "_options")), keyword(ast)}
  end

  # The fields of `[key: spec, ...] | %{...}`, in order.
  defp keyword({:type, _, :union, [{:type, _, :list, [union]} | _]}), do: fields(union)

  defp fields({:type, _, :union, tuples}), do: Enum.map(tuples, &field/1)
  defp fields(tuple), do: [field(tuple)]

  defp field({:type, _, :tuple, [{:atom, _, key}, value]}) do
    {:"::", _, [_, quoted]} = Code.Typespec.type_to_quoted({:value, value, []})
    {key, Macro.to_string(quoted)}
  end
end
