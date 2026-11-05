defmodule Mix.PlaywrightEx.TestRegistryTest do
  use ExUnit.Case, async: true

  alias Mix.PlaywrightEx.TestRegistry

  @registry """
  ## Subsystems

  | Code | Subsystem | Files |
  |---|---|---|
  | `CC` | Client certificates | `library/client-certificates` |

  ## Tests

  | ID | File | Title |
  |---|---|---|
  | `CC-001` | `library/client-certificates.spec.ts` | fetch › validate input |
  | `CC-013` | `library/client-certificates.spec.ts` | browser › validate input |
  | `CC-040` | `library/client-certificates.spec.ts` | browser › persistentContext › validate input |
  | `CC-041` | `library/client-certificates.spec.ts` | should escape \\`a\\` |
  | `BC-073` | `library/browsercontext-reuse.spec.ts` | reuse {launch, connect} › should reset *(2 copies)* |
  """

  @rules """
  # comment
  CC-041      Some reason.
  library/browsercontext-*  Another reason.
  CC
  """

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "registry.md"), @registry)
    File.write!(Path.join(tmp_dir, "rules.txt"), @rules)
    {rows, subsystems} = TestRegistry.read_registry(Path.join(tmp_dir, "registry.md"))
    {rules, problems} = TestRegistry.read_rules(Path.join(tmp_dir, "rules.txt"))
    %{rows: rows, subsystems: subsystems, rules: rules, problems: problems}
  end

  test "read_registry/1: rows with their variants, subsystems", %{rows: rows, subsystems: subsystems} do
    assert subsystems == [{"CC", "Client certificates"}]
    assert Enum.map(rows, & &1.id) == ~w(CC-001 CC-013 CC-040 CC-041 BC-073)
    assert Enum.at(rows, 3).title == "should escape `a`"
    assert %{file: "library/browsercontext-reuse", copies: 2} = reuse = List.last(rows)
    assert reuse.variants == [{["reuse launch"], "should reset"}, {["reuse connect"], "should reset"}]
  end

  test "read_rules/1: selector and reason per line, a rule without a reason is a problem", %{rules: rules} = ctx do
    assert [%{line: 2, selector: "CC-041", reason: "Some reason."}, %{selector: "library/browsercontext-*"}] = rules
    assert ctx.problems == ["rules.txt:4: the rule has no reason"]
  end

  test "rule_for/2: by ID, subsystem code or file glob", %{rows: rows, rules: rules} do
    assert Enum.map(rows, &(TestRegistry.rule_for(&1, rules) && TestRegistry.rule_for(&1, rules).line)) ==
             [nil, nil, nil, 2, 3]

    assert TestRegistry.matches?(%{selector: "CC"}, hd(rows))
  end

  test "match/3: by title, then by describe", %{rows: rows} do
    cc = Enum.filter(rows, &(&1.file == "library/client-certificates"))
    assert {:ok, %{id: "CC-013"}} = TestRegistry.match(cc, "browser", "validate input")
    assert {:ok, %{id: "CC-040"}} = TestRegistry.match(cc, "browser persistentContext", "validate input")
    assert {:ok, %{id: "CC-040"}} = TestRegistry.match(cc, "persistentContext", "validate input")
    assert {:ambiguous, [_, _, _]} = TestRegistry.match(cc, :dynamic, "validate input")
    assert {:ok, %{id: "CC-041"}} = TestRegistry.match(cc, :dynamic, "should escape `a`")
    assert :none = TestRegistry.match(cc, nil, "gone")
    assert {:pattern, [%{id: "CC-041"}]} = TestRegistry.match(cc, nil, ~r/^should escape .*$/)
  end

  test "test_modules/1: tests with describe, body and static skip reasons" do
    source = ~S'''
    defmodule T do
      @upstream "tests/page/x.spec.ts"
      @moduletag skip: "upstream skip: " <> "all"
      @tag skip: "not ported: a"
      test "a"
      describe "d" do
        @tag skip: if(true, do: "env: x")
        test "b", %{} do
        end
      end
      for x <- [1, 2] do
        describe "loop #{x}" do
          test "c #{x}"
        end
      end
    end
    '''

    assert [{"tests/page/x.spec.ts", [a, b, c]}] = TestRegistry.test_modules(source)
    assert %{name: "a", describe: nil, body?: false, skips: ["not ported: a", "upstream skip: all"]} = a
    assert %{name: "b", describe: "d", body?: true, skips: ["upstream skip: all"]} = b
    assert %{describe: :dynamic, body?: false} = c
    assert Regex.match?(c.name, "c 1")
  end
end
