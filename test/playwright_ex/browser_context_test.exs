defmodule PlaywrightEx.BrowserContextTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame

  describe "add_init_script/2" do
    test "applies script to newly created pages", %{browser_context: browser_context} do
      assert {:ok, _} =
               BrowserContext.add_init_script(browser_context.guid,
                 source: "window.__browser_context_add_init_script = 'ok';",
                 timeout: @timeout
               )

      {:ok, page} = BrowserContext.new_page(browser_context.guid, timeout: @timeout)
      {:ok, _} = Frame.goto(page.main_frame.guid, url: "about:blank", timeout: @timeout)

      assert {:ok, "ok"} = eval(page.main_frame.guid, "() => window.__browser_context_add_init_script")
    end
  end
end
