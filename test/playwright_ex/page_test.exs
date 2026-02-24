defmodule PlaywrightEx.PageTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page

  describe "add_init_script/2" do
    test "applies script on navigation", %{page: page, frame: frame} do
      assert {:ok, _} =
               Page.add_init_script(page.guid,
                 source: "window.__page_add_init_script = 'ok';",
                 timeout: @timeout
               )

      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      assert {:ok, "ok"} = eval(frame.guid, "() => window.__page_add_init_script")
    end
  end
end
