defmodule PlaywrightEx.Page.PageClickTimeout2Test do
  @upstream "tests/page/page-click-timeout-2.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  test "CL-114 should timeout waiting for display:none to be gone", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", "b => b.style.display = 'none'")
    {:error, error} = Page.click(page, "button", timeout: 5000)
    assert Exception.message(error) =~ "page.click: Timeout 5000ms exceeded."
    assert Exception.message(error) =~ "waiting for element to be visible, enabled and stable"
    assert Exception.message(error) =~ "element is not visible"
    assert Exception.message(error) =~ "retrying click action"
  end

  test "CL-115 should timeout waiting for visibility:hidden to be gone", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", "b => b.style.visibility = 'hidden'")
    {:error, error} = Page.click(page, "button", timeout: 5000)
    assert Exception.message(error) =~ "page.click: Timeout 5000ms exceeded."
    assert Exception.message(error) =~ "waiting for element to be visible, enabled and stable"
    assert Exception.message(error) =~ "element is not visible"
    assert Exception.message(error) =~ "retrying click action"
  end
end
