defmodule Mix.Tasks.PlaywrightEx.ParityTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.PlaywrightEx.Parity

  test "ts_members/1: class methods and top-level functions, in order" do
    source = """
    export class Browser extends ChannelOwner<channels.BrowserChannel> implements api.Browser {
      readonly _contexts = new Set<BrowserContext>();
      private _isConnected = true;
      static from(browser: channels.BrowserChannel): Browser {
        return (browser as any)._object;
      }
      async newContext(options: BrowserContextOptions = {}): Promise<BrowserContext> {
        if (x) {
          foo();
        }
      }
      private _didCreateContext(context: BrowserContext) {}
      get _name(): string {}
      waitForEvent<T>(event: string): Promise<T>;
      async [Symbol.asyncDispose]() {}
    }

    interface Transport {
      send(message: string): void;
    }

    export function isTargetClosedError(error: Error) {}
    function checkListener(listener: any) {}
    """

    assert Parity.ts_members(source) == [
             {"Browser", "from"},
             {"Browser", "newContext"},
             {"Browser", "_didCreateContext"},
             {"Browser", "_name"},
             {"Browser", "waitForEvent"},
             {nil, "isTargetClosedError"},
             {nil, "checkListener"}
           ]
  end

  test "root_module/2: the only declaring module, else the one named after the file" do
    mod = &%{name: &1, declares_upstream: &2}
    request = mod.(PlaywrightEx.Client.Request, true)
    network = mod.(PlaywrightEx.Client.Network, true)
    root = mod.(PlaywrightEx.Client.Connection.Root, false)
    connection = mod.(PlaywrightEx.Client.Connection, true)
    keyboard = mod.(PlaywrightEx.Client.Keyboard, true)
    mouse = mod.(PlaywrightEx.Client.Mouse, true)

    assert Parity.root_module("src/client/network.ts", [request, network]) == network
    assert Parity.root_module("src/client/connection.ts", [root, connection]) == connection
    assert Parity.root_module("src/client/input.ts", [keyboard, mouse]) == nil
  end

  test "spec_tests/1: static names, flattened, dynamic ones skipped" do
    source = ~S"""
    it('should work', async ({ page }) => {});
    it.describe('nested', () => {
      test.fixme("should handle \"quotes\"", async () => {});
      it(`should be a template`, async () => {});
      it(`should be ${dynamic}`, async () => {});
      it('should be ' + name, async () => {});
      test.describe.configure({ mode: 'serial' });
      test.step('not a test', async () => {});
    });
    browserTest('should work', async ({ browser }) => {});
    """

    assert Parity.spec_tests(source) == [
             "should work",
             ~s(should handle "quotes"),
             "should be a template",
             "should work"
           ]
  end

  test "unordered/2: names outside the longest common subsequence, unknown names ignored" do
    assert Parity.unordered(~w(a b c d e), ~w(a d b x c e)) == ["d"]
    assert Parity.unordered(~w(a b c d), ~w(b c d a)) == ["a"]
    assert Parity.unordered(~w(a b), ~w(a b)) == []
  end

  @tag :tmp_dir
  test "ported_in_order/1: functions and module-level marker names, in file order", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "page.ex")

    File.write!(file, """
    defmodule Page do
      def b(this), do: this

      # a, c  -- not ported: reason
      def d(this) do
        # e  -- not ported: inside a body
        this
      end

      defp b(this, _), do: this

      defmodule Nested do
        # f  -- ported as g/1
        def g(this), do: this
      end
    end
    """)

    [page, nested] = Parity.elixir_modules(file)
    assert Parity.ported_in_order(page) == ~w(b a c d b)
    assert Parity.ported_in_order(nested) == ~w(f g)
  end

  test "skip_reasons/1: static reasons of skip tags, with their lines" do
    source = ~S"""
    defmodule T do
      @no_server "not ported: TestServer.close"
      @moduletag skip: if(@browser_name == "webkit", do: "upstream skip: webkit")

      @tag skip: "not ported: Page.emulateMedia"
      test "a"

      describe "nested" do
        @tag :page
        @tag skip:
               "not ported: Page.pdf " <>
                 "(chromium only)"
        test "b"
      end

      @tag skip: (case @browser_name do
                    "firefox" -> "not ported: Worker.waitForEvent"
                    _ -> false
                  end)
      test "c"

      @tag skip: @no_server
      test "d"

      @tag skip: System.get_env("SKIP")
      test "e"
    end
    """

    assert Parity.skip_reasons(source) == [
             {3, "upstream skip: webkit"},
             {5, "not ported: Page.emulateMedia"},
             {10, "not ported: Page.pdf (chromium only)"},
             {16, "not ported: Worker.waitForEvent"},
             {22, "not ported: TestServer.close"}
           ]
  end

  test "conditional_annotation?/2 and upstream_test_bodies/2: conditions that vary between our runs" do
    source = """
    it('a', async ({ browserName }) => {
      it.skip(browserName !== 'webkit', 'webkit only');
      it.fail(browserName === 'chromium');
    });
    it('b', async ({ headless, browserName }) => {
      it.skip(browserName !== 'webkit' || headless, 'headed webkit');
      it.fixme(true, 'always');
      it.fail(mode !== 'default');
    });
    """

    [a] = Parity.upstream_test_bodies(source, "a")
    [b] = Parity.upstream_test_bodies(source, "b")
    assert Parity.upstream_test_bodies(source, "c") == []
    assert String.contains?(a, "webkit only") and not String.contains?(a, "headed webkit")
    assert Parity.conditional_annotation?(a, "skip")
    assert Parity.conditional_annotation?(a, "fail")
    refute Parity.conditional_annotation?(a, "fixme")
    refute Parity.conditional_annotation?(b, "skip")
    refute Parity.conditional_annotation?(b, "fixme")
    refute Parity.conditional_annotation?(b, "fail")
  end

  @tag :tmp_dir
  test "slow_scopes/1 and check_slow/2: upstream slow() needs a timeout tag using @slow_timeout", %{tmp_dir: dir} do
    assert Parity.slow_scopes("test.slow();\nit('a', () => {});\n") == [:file]

    source = """
    it.describe('d', () => {
      it.beforeEach(async () => {
        it.slow();
      });
      it('a', async ({ page }) => {
        it.slow(trace === 'on');
      });
    });
    it('b', {
      annotation: { type: 'issue' },
    }, async ({ page }) => {
      it.slow(true, 'Large');
    });
    """

    assert Parity.slow_scopes(source) == [{:describe, "d"}, {:test, "b", :file}]

    File.mkdir_p!(Path.join(dir, "tests"))
    File.write!(Path.join(dir, "tests/x.spec.ts"), source)
    test = &%{name: &1, describe: &2, body?: true, slow?: &3, spec: "tests/x.spec.ts", file: "x_test.exs", line: 1}
    tests = [test.("a", "d", false), test.("a", nil, false), test.("b", nil, true), test.("c", "d", true)]

    assert Parity.check_slow(dir, tests) == [
             ~s|x_test.exs:1: "a" is `slow()` upstream: tag it `timeout: @slow_timeout`|
           ]
  end

  test "cited_members/1: Class.member names outside parentheses of a reason that only lists API names" do
    assert Parity.cited_members("not ported: Page.emulateMedia") == [{"Page", "emulateMedia"}]
    assert Parity.cited_members("not ported: Locator.evaluate (ElementHandle), expect") == [{"Locator", "evaluate"}]

    assert Parity.cited_members("not ported: waitForEvent, JSHandle.jsonValue and BrowserContext.storageState") ==
             [{"JSHandle", "jsonValue"}, {"BrowserContext", "storageState"}]

    assert Parity.cited_members("not ported: Page.removeAllListeners (behavior option)") ==
             [{"Page", "removeAllListeners"}]

    # Prose explains why a member that exists still cannot be used.
    assert Parity.cited_members("not ported: Page.removeAllListeners behavior option") == []
    assert Parity.cited_members("not ported: EventEmitter.emit with several arguments (one event argument)") == []
    # Names in parentheses are context, not citations.
    assert Parity.cited_members(
             "not ported: toImpl (server internals: Frame.nonStallingRawEvaluateInExistingMainContext)"
           ) ==
             []

    assert Parity.cited_members("not ported: utils.parsePattern (server-side)") == []
    assert Parity.cited_members("upstream fixme: Page.emulateMedia") == []
  end

  test "ported?/2: the client or the facade exports the snake_case member" do
    assert Parity.ported?("Page", "emulateMedia")
    assert Parity.ported?("APIRequestContext", "storageState")
    refute Parity.ported?("Frame", "nonStallingRawEvaluateInExistingMainContext")
    refute Parity.ported?("Promise", "then")
  end

  @tag :tmp_dir
  test "check_skips/2: a stale skip per cited member that is ported", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "page_test.exs")

    File.write!(file, ~S"""
    defmodule PageTest do
      @tag skip: "not ported: Page.emulateMedia, Page.requestGC"
      test "a"
    end
    """)

    assert Parity.check_skips([file], fn _, member -> member == "emulateMedia" end) ==
             ["stale skip: #{file}:2 cites Page.emulateMedia, which is ported"]
  end

  test "check_files/4: unclaimed files that are not excluded, and stale exclusions" do
    files = ~w(a.ts b.ts c.ts d.ts)
    claimed = MapSet.new(~w(a.ts d.ts other.ts))
    exclusions = %{"b.ts" => "type-only", "d.ts" => "ported since", "gone.ts" => "removed upstream"}

    assert Parity.check_files(files, claimed, exclusions, "no module") == [
             "c.ts: no module",
             "d.ts: excluded but has a module with `@upstream` for it, drop the exclusion",
             "gone.ts: excluded but not found upstream, drop the exclusion"
           ]

    assert Parity.check_files(~w(a.ts b.ts), claimed, %{"b.ts" => "type-only"}, "no module") == []
  end

  @tag :tmp_dir
  test "check_registry/1: tests at the pin ported, upstream-skipped or ruled out; rules that match", %{tmp_dir: dir} do
    write = fn path, content ->
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    write.("up/tests/page/a.spec.ts", """
    it('ported', async () => {});
    it('ported and ruled out', async () => {});
    it('bodiless', async () => {});
    it('upstream skipped', async () => {});
    """)

    write.("up/tests/page/b.spec.ts", "it('unmirrored', async () => {});\n")
    write.("up/tests/page/c.spec.ts", "it('ruled out file', async () => {});\n")
    write.("up/tests/page/d.spec.ts", "it('not in the registry', async () => {});\n")

    write.("a_test.exs", """
    defmodule ATest do
      @upstream "tests/page/a.spec.ts"
      test "ported", do: :ok
      test "ported and ruled out", do: :ok
      test "bodiless"
      @tag skip: "upstream fixme: x"
      test "upstream skipped"
      test "not upstream", do: :ok
    end
    """)

    write.("registry.md", """
    | `AA-001` | `page/a.spec.ts` | ported |
    | `AA-002` | `page/a.spec.ts` | ported and ruled out |
    | `AA-003` | `page/a.spec.ts` | bodiless |
    | `AA-004` | `page/a.spec.ts` | upstream skipped |
    | `AA-005` | `page/a.spec.ts` | newer than the pin |
    | `BB-001` | `page/b.spec.ts` | unmirrored |
    | `CC-001` | `page/c.spec.ts` | ruled out file |
    """)

    write.("rules.txt", """
    AA-002    Reason.
    AA-005    Not at the pin.
    page/c    Whole file.
    """)

    registry =
      Parity.registry(
        Path.join(dir, "up"),
        [Path.join(dir, "a_test.exs")],
        Path.join(dir, "registry.md"),
        Path.join(dir, "rules.txt")
      )

    assert registry.absent == 1

    assert Parity.check_registry(registry) == [
             "AA-002 (page/a: ported and ruled out) is ported, but upstream_not_ported.txt:1 rules it out",
             "AA-003 (page/a: bodiless) is neither ported (a test with a body) nor ruled out in upstream_not_ported.txt",
             "tests/page/b.spec.ts: no test module with `@upstream` for it, and 1 of its tests (BB-001) are not " <>
               "ruled out in upstream_not_ported.txt: mirror it or rule them out",
             "tests/page/d.spec.ts: no test module with `@upstream` for it, and not in the registry: mirror it",
             "upstream_not_ported.txt:2: AA-005 matches no registry test at the pin"
           ]

    assert ["registry: 1 tests not at the pin (ignored), 1 mirrored tests not matched", "  " <> _] =
             Parity.registry_info(registry)
  end
end
