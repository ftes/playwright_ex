defmodule PlaywrightEx.Page.PageClickReactTest do
  @upstream "tests/page/page-click-react.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise

  @moduletag :page

  test "should timeout when click opens alert", %{page: page} do
    dialog_promise = Page.wait_for_event(page, :dialog)
    Page.set_content!(page, "<div onclick='window.alert(123)'>Click me</div>")
    {:error, error} = Page.click(page, "div", timeout: 3000)
    assert Exception.message(error) =~ "page.click: Timeout 3000ms exceeded."
    dialog = Promise.await!(dialog_promise)
    Dialog.dismiss!(dialog)
  end

  test "should not retarget when element changes on hover", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/react.html")

    Page.evaluate!(page, """
    () => {
      renderComponent(e('div', {}, [e(MyButton, { name: 'button1', renameOnHover: true }), e(MyButton, { name: 'button2' })]));
    }
    """)

    Page.click!(page, "text=button1")
    assert Page.evaluate!(page, "window.button1") == true
    assert Page.evaluate!(page, "window.button2") == nil
  end

  test "should not retarget when element is recycled on hover", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/react.html")

    Page.evaluate!(page, """
    () => {
      function shuffle() {
        renderComponent(e('div', {}, [e(MyButton, { name: 'button2' }), e(MyButton, { name: 'button1' })]));
      }
      renderComponent(e('div', {}, [e(MyButton, { name: 'button1', onHover: shuffle }), e(MyButton, { name: 'button2' })]));
    }
    """)

    Page.click!(page, "text=button1")
    assert Page.evaluate!(page, "window.button1") == nil
    assert Page.evaluate!(page, "window.button2") == true
  end
end
