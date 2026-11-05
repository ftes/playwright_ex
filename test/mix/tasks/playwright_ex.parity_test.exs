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
end
