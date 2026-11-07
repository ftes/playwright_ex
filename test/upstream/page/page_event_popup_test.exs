defmodule PlaywrightEx.Page.PageEventPopupTest do
  @upstream "tests/page/page-event-popup.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime

  @moduletag :page

  defp opener?(page), do: Page.evaluate!(page, "() => !!window.opener")

  test "PO-001 should work @smoke", %{page: page} do
    popup = Page.wait_for_event(page, :popup)
    Page.evaluate!(page, "() => window['__popup'] = window.open('about:blank')")
    popup = Promise.await!(popup)
    assert opener?(page) == false
    assert opener?(popup) == true
  end

  test "PO-002 should work with window features", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(
          page,
          "() => window['__popup'] = window.open(window.location.href, 'Title', 'toolbar=no,location=no,directories=no,status=no,menubar=no,scrollbars=yes,resizable=yes,width=780,height=200,top=0,left=0')"
        )
      end)

    assert opener?(page) == false
    assert opener?(popup) == true
  end

  test "PO-003 should emit for immediately closed popups", %{page: page} do
    popup =
      Page.expect_event!(page, :popup, fn ->
        Page.evaluate!(page, """
        () => {
          const win = window.open('about:blank');
          win.close();
        }
        """)
      end)

    assert popup
  end

  test "PO-004 should emit for immediately closed popups 2", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, """
        () => {
          const win = window.open(window.location.href);
          win.close();
        }
        """)
      end)

    assert popup
  end

  test "PO-005 should be able to capture alert", %{page: page} do
    # Deviation: the waits are set up before the evaluate starts (JS attaches them in the same tick).
    popup_promise = Page.wait_for_event(page, :popup)
    dialog_promise = BrowserContext.wait_for_event(Page.context(page), :dialog)

    evaluate_promise =
      Runtime.Promise.async(fn ->
        Page.evaluate!(page, """
        () => {
          const win = window.open('');
          win.alert('hello');
        }
        """)
      end)

    popup = Promise.await!(popup_promise)
    dialog = Promise.await!(dialog_promise)
    assert Dialog.message(dialog) == "hello"
    assert Dialog.page(dialog) == popup
    Dialog.dismiss!(dialog)
    Runtime.Promise.await(evaluate_promise)
  end

  test "PO-006 should work with empty url", %{page: page} do
    popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => window['__popup'] = window.open('')") end)
    assert opener?(page) == false
    assert opener?(popup) == true
  end

  test "PO-007 should work with noopener and no url", %{page: page} do
    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "() => window['__popup'] = window.open(undefined, null, 'noopener')")
      end)

    # Chromium reports `about:blank#blocked` here.
    assert hd(String.split(Page.url(popup), "#")) == "about:blank"
    assert opener?(page) == false
    assert opener?(popup) == false
  end

  test "PO-008 should work with noopener and about:blank", %{page: page} do
    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "() => window['__popup'] = window.open('about:blank', null, 'noopener')")
      end)

    assert opener?(page) == false
    assert opener?(popup) == false
  end

  test "PO-009 should work with noopener and url", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "url => window['__popup'] = window.open(url, null, 'noopener')", server.empty_page)
      end)

    assert opener?(page) == false
    assert opener?(popup) == false
  end

  test "PO-010 should work with clicking target=_blank", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a target=_blank rel="opener" href="/one-style.html">yo</a>))
    popup = Page.expect_popup!(page, fn -> Page.click!(page, "a") end)
    assert opener?(page) == false
    assert opener?(popup) == true
    assert Frame.page(Page.main_frame(popup)) == popup
  end

  test "PO-011 should work with fake-clicking target=_blank and rel=noopener", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a target=_blank rel=noopener href="/one-style.html">yo</a>))
    popup = Page.expect_popup!(page, fn -> Page.eval_on_selector!(page, "a", "a => a.click()") end)
    assert opener?(page) == false
    assert opener?(popup) == false
  end

  test "PO-012 should work with clicking target=_blank and rel=noopener", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a target=_blank rel=noopener href="/one-style.html">yo</a>))
    popup = Page.expect_popup!(page, fn -> Page.click!(page, "a") end)
    assert opener?(page) == false
    assert opener?(popup) == false
  end

  test "PO-013 should report popup opened from iframes", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/two-frames.html")
    frame = Enum.at(Page.frames(page), 1)
    assert frame
    popup = Page.expect_popup!(page, fn -> Frame.evaluate!(frame, "() => window.open('')") end)
    assert popup
  end
end
