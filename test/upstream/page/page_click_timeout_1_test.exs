defmodule PlaywrightEx.Page.PageClickTimeout1Test do
  @upstream "tests/page/page-click-timeout-1.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  # it.skip(mode !== 'default'): __testHookBeforePointerAction is an in-process JS function.
  test "CL-110 should avoid side effects after timeout"

  test "CL-111 should timeout waiting for button to be enabled", %{page: page} do
    Page.set_content!(
      page,
      ~s(<button onclick="javascript:window.__CLICKED=true;" disabled><span>Click target</span></button>)
    )

    {:error, error} = Page.click(page, "text=Click target", timeout: 3000)
    assert Page.evaluate!(page, "window.__CLICKED") == nil
    assert Exception.message(error) =~ "page.click: Timeout 3000ms exceeded."
    assert Exception.message(error) =~ "element is not enabled"
    assert Exception.message(error) =~ "retrying click action"
  end
end
