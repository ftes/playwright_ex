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
end
