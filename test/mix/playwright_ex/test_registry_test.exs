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

  test "read_registry/1: rows, subsystems", %{rows: rows, subsystems: subsystems} do
    assert subsystems == [{"CC", "Client certificates"}]
    assert Enum.map(rows, & &1.id) == ~w(CC-001 CC-013 CC-040 CC-041 BC-073)
    assert Enum.at(rows, 3).title == "should escape `a`"

    assert %{file: "library/browsercontext-reuse", copies: 2, title: "reuse {launch, connect} › should reset"} =
             List.last(rows)
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

  test "match/2: by identifier, in the rows of the file", %{rows: rows} do
    cc = Enum.filter(rows, &(&1.file == "library/client-certificates"))
    assert {:ok, %{id: "CC-040"}} = TestRegistry.match(cc, "CC-040")
    assert :none = TestRegistry.match(cc, "BC-073")
    assert :none = TestRegistry.match(cc, nil)
  end

  test "id/1: the identifier a name starts with, also of a name built at runtime" do
    assert TestRegistry.id("CC-040 validate input") == "CC-040"
    assert TestRegistry.id("CL-PY-001 a") == "CL-PY-001"
    assert TestRegistry.id(Code.string_to_quoted!(~S'"PR-005 #{description}"')) == "PR-005"
    assert TestRegistry.id(Code.string_to_quoted!(~S'"PR-005 " <> description')) == "PR-005"
    assert TestRegistry.id("validate input") == nil
    assert TestRegistry.id("CC-040") == nil
  end

  test "test_modules/1: tests with describe, body and static skip reasons" do
    source = ~S'''
    defmodule T do
      @upstream "tests/page/x.spec.ts"
      @moduletag skip: "upstream skip: " <> "all"
      @tag skip: "not ported: a"
      test "XX-001 a"
      describe "d" do
        @tag skip: if(true, do: "env: x")
        test "XX-002 b", %{} do
        end
      end
      for x <- [1, 2] do
        describe "loop #{x}" do
          test "XX-003 c #{x}"
        end
      end
    end
    '''

    assert [{"tests/page/x.spec.ts", [a, b, c]}] = TestRegistry.test_modules(source)

    assert %{
             name: "XX-001 a",
             id: "XX-001",
             describe: nil,
             body?: false,
             skips: ["not ported: a", "upstream skip: all"]
           } = a

    assert %{name: "XX-002 b", id: "XX-002", describe: "d", body?: true, skips: ["upstream skip: all"]} = b
    assert %{id: "XX-003", describe: :dynamic, body?: false} = c
    assert Regex.match?(c.name, "XX-003 c 1")
  end

  test "test_modules/1: slow? from a timeout tag using @slow_timeout" do
    source = ~S'''
    defmodule T do
      @upstream "tests/page/x.spec.ts"
      @tag timeout: @slow_timeout
      test "a"
      @tag timeout: 5_000
      test "b"
      describe "d" do
        @describetag timeout: if(true, do: @slow_timeout, else: 1)
        test "c"
      end
    end
    defmodule U do
      @upstream "tests/page/y.spec.ts"
      if true, do: @moduletag(timeout: 2 * @slow_timeout)
      test "e"
    end
    '''

    assert [{_, [a, b, c]}, {_, [e]}] = TestRegistry.test_modules(source)
    assert a.slow? and c.slow? and e.slow?
    refute b.slow?
  end
end
