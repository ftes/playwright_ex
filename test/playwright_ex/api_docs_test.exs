defmodule PlaywrightEx.ApiDocsTest do
  # The prose of the generated facade's docs (code blocks aside) reads as Elixir: an upstream
  # version that brings new JS-isms fails here. Fix them with a rule in `mix playwright_ex.gen.api`
  # ("JS names in prose") or an override in `Mix.PlaywrightEx.ApiRules` (`@prose_overrides`).
  use ExUnit.Case, async: true

  # Backticked camelCase names that are facade options too, but mean something else here.
  @allowed_names []

  @modules for path <- Path.wildcard("lib/playwright_ex/api/*.ex"),
               [_, name] <- [Regex.run(~r/^defmodule (\S+) do/m, File.read!(path))],
               do: Module.concat([name])

  setup_all do
    docs = for module <- @modules, doc <- docs(module), do: doc
    types = Map.new(@modules, &{&1, option_types(&1)})
    options = for {_module, types} <- types, {_type, keys} <- types, key <- keys, into: MapSet.new(), do: key
    %{docs: docs, types: types, options: options}
  end

  test "no JS `null` or `undefined`: `nil`, or `:null` passed in", %{docs: docs} do
    assert offending(docs, ~r/`(?:null|undefined)`/) == []
  end

  test "no JS names of options or arguments: `:snake_case` options, Elixir arguments", %{
    docs: docs,
    types: types,
    options: options
  } do
    js_names =
      for {module, function, signature, prose} <- docs,
          [name] <- Regex.scan(~r/`([a-z][a-z0-9]*[A-Z]\w*)`/, prose, capture: :all_but_first),
          name not in @allowed_names,
          own = own_names(types[module], function, signature),
          Macro.underscore(name) in own or String.to_atom(Macro.underscore(name)) in options,
          do: "#{inspect(module)}.#{function}: `#{name}`"

    assert js_names == []
  end

  test "no positional argument by its JS name (`pageFunction` is `expression`)", %{docs: docs} do
    assert offending(docs, ~r/`(?:pageFunction|optionsOr[A-Z]\w*)`/) == []
  end

  test "no JS calls on a facade class: a function link (`PlaywrightEx.Page.goto/3`)", %{docs: docs} do
    receivers = Map.new(@modules, &{receiver(&1), &1})

    calls =
      for {module, function, _signature, prose} <- docs,
          [call, receiver, member] <-
            Regex.scan(~r/`([a-z]\w*)(?:\(\))?\.([a-z]\w*)(?:\([^`]*\))?`/, prose),
          target = receivers[receiver],
          snake = String.to_atom(Macro.underscore(member)),
          Enum.any?(target.__info__(:functions), &(elem(&1, 0) == snake)),
          do: "#{inspect(module)}.#{function}: #{call}"

    assert calls == []
  end

  test "no raw upstream member refs (`[method: Page.goto]`), also in `deprecated:`", %{docs: docs} do
    deprecated =
      for module <- @modules,
          {:docs_v1, _, _, _, _, _, entries} = Code.fetch_docs(module),
          {{_, name, arity}, _, _, _, %{deprecated: text}} <- entries,
          do: {module, "#{name}/#{arity} deprecated", "", text}

    assert offending(docs ++ deprecated, ~r/\[`?(?:method|property|event|param|option): /) == []
    # ExDoc shows `deprecated:` as plain text.
    assert offending(deprecated, ~r/[`\[]/) == []
  end

  test "no unresolved bracket refs (`[UIEvent.detail]`, `[request]`): links or code", %{docs: docs} do
    docs = for {module, function, signature, prose} <- docs, do: {module, function, signature, without_code(prose)}
    assert offending(docs, ~r/\[[A-Za-z][\w.]*\](?![(:\[])/) == []
  end

  # Until our versions are Playwright's: "*Since Playwright 1.8.*" in the text.
  test "no `since:` metadata (it would read as a PlaywrightEx version)" do
    with_since =
      for module <- @modules,
          {:docs_v1, _, _, _, _, module_meta, entries} = Code.fetch_docs(module),
          {name, meta} <- [{"moduledoc", module_meta} | for({{_, n, a}, _, _, _, m} <- entries, do: {"#{n}/#{a}", m})],
          Map.has_key?(meta, :since),
          do: "#{inspect(module)}.#{name}"

    assert with_since == []
  end

  defp offending(docs, regex) do
    for {module, function, _signature, prose} <- docs,
        [match | _] <- Regex.scan(regex, prose),
        do: "#{inspect(module)}.#{function}: #{match}"
  end

  # {module, "name/arity" | "moduledoc", signature, prose}: fenced code blocks removed (also in
  # admonitions, `> ```elixir`).
  defp docs(module) do
    {:docs_v1, _, _, _, moduledoc, _, entries} = Code.fetch_docs(module)
    module_entry = for %{"en" => doc} <- [moduledoc], do: {module, "moduledoc", "", prose(doc)}

    module_entry ++
      for {{_kind, name, arity}, _, [signature | _], %{"en" => doc}, _} <- entries,
          do: {module, "#{name}/#{arity}", signature, prose(doc)}
  end

  defp prose(doc) do
    doc
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {lines, code?} ->
      cond do
        line =~ ~r/^[\s>]*```/ -> {lines, not code?}
        code? -> {lines, code?}
        true -> {[line | lines], code?}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # Inline code spans removed (`[contenteditable]` is code).
  defp without_code(prose), do: Regex.replace(~r/`[^`]*`/, prose, "")

  # The options (`@type <name>_options`) and arguments of a function, snake_case strings.
  defp own_names(_types, "moduledoc", _signature), do: []

  defp own_names(types, function, signature) do
    name = function |> String.split("/") |> hd() |> String.trim_trailing("!")
    options = types |> Map.get(:"#{name}_options", []) |> Enum.map(&Atom.to_string/1)
    options ++ List.flatten(Regex.scan(~r/[(,]\s*([a-z_]\w*)/, signature, capture: :all_but_first))
  end

  # %{type => option keys}: the keyword list of each `<name>_options` type.
  defp option_types(module) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    for {:type, {type, ast, []}} <- types,
        String.ends_with?(Atom.to_string(type), "_options"),
        into: %{},
        do: {type, keys(ast)}
  end

  defp keys({:type, _, :tuple, [{:atom, _, key}, _value]}), do: [key]
  defp keys({:type, _, _, args}) when is_list(args), do: Enum.flat_map(args, &keys/1)
  defp keys(_ast), do: []

  # `PlaywrightEx.BrowserContext` -> "browserContext", `PlaywrightEx.JSHandle` -> "jsHandle".
  defp receiver(module) do
    [_, head, rest] = Regex.run(~r/^(API|JS|CDP|[A-Z])(.*)$/, module |> Module.split() |> List.last())
    String.downcase(head) <> rest
  end
end
