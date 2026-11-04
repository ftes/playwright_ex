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
end
