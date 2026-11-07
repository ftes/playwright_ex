defmodule PlaywrightEx.PublicDocsTest do
  # Every public function that hexdocs shows has a doc and a spec. The modules are those of
  # `mix docs`: lib/ and dev/ modules that mix.exs `docs/0` `filter_modules` keeps, without
  # `@moduledoc false`.
  use ExUnit.Case, async: true

  setup_all do
    filter = Mix.Project.config()[:docs][:filter_modules]

    modules =
      for module <- Application.spec(:playwright_ex, :modules),
          source = to_string(module.module_info(:compile)[:source]),
          # `mix docs` runs in dev: lib/ and dev/, no test/support.
          not String.starts_with?(Path.relative_to_cwd(source), "test/"),
          filter.(module, %{source_path: source}),
          {:docs_v1, _, _, _, moduledoc, _, entries} = Code.fetch_docs(module),
          moduledoc != :hidden,
          do: {module, entries}

    %{modules: modules, filter: filter}
  end

  test "hexdocs shows the modules it should", %{modules: modules} do
    shown = Enum.map(modules, &elem(&1, 0))
    assert PlaywrightEx.Driver in shown
    assert PlaywrightEx.Page in shown
    assert Mix.Tasks.PlaywrightEx.Install in shown
    assert Mix.Tasks.PlaywrightEx.Cli in shown
    refute PlaywrightEx.Client.Page in shown
    # dev/: maintainer tooling.
    refute Mix.Tasks.PlaywrightEx.Parity in shown
    refute Mix.PlaywrightEx.TestRegistry in shown
    refute PlaywrightEx.Upstream in shown
  end

  test "the docs filter ignores where the checkout lives", %{filter: filter} do
    for checkout <- ["/home/me/dev/playwright_ex", "/srv/lib/playwright_ex/client/mix"] do
      shown? = &filter.(nil, %{source_path: Path.join(checkout, &1)})
      assert shown?.("lib/playwright_ex.ex")
      assert shown?.("lib/playwright_ex/page.ex")
      assert shown?.("lib/mix/tasks/playwright_ex.install.ex")
      refute shown?.("lib/playwright_ex/client/page.ex")
      refute shown?.("lib/playwright_ex/out_of_process.ex")
      refute shown?.("dev/playwright_ex/upstream.ex")
      refute shown?.("dev/mix/tasks/playwright_ex.parity.ex")
      refute shown?.("dev/mix/playwright_ex/test_registry.ex")
    end
  end

  test "every public function hexdocs shows has a @doc", %{modules: modules} do
    undocumented =
      for {module, entries} <- modules,
          {{kind, name, arity}, _, _, :none, _} <- entries,
          kind in [:function, :macro],
          do: "#{inspect(module)}.#{name}/#{arity}"

    assert undocumented == []
  end

  test "every public function hexdocs shows has a @spec", %{modules: modules} do
    unspecced =
      for {module, entries} <- modules,
          specs = specs(module),
          {{:function, name, arity}, _, _, %{"en" => doc}, _} <- entries,
          not generated_child_spec?(name, arity, doc),
          {name, arity} not in specs,
          do: "#{inspect(module)}.#{name}/#{arity}"

    assert unspecced == []
  end

  # `use GenServer`/`use Supervisor`'s `child_spec/1`, documented as such.
  defp generated_child_spec?(name, arity, doc),
    do: {name, arity} == {:child_spec, 1} and doc =~ "Returns a specification to start this module under a supervisor"

  defp specs(module) do
    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} -> for {name_arity, _} <- specs, do: name_arity
      :error -> []
    end
  end
end
