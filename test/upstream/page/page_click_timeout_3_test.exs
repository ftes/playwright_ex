defmodule PlaywrightEx.Page.PageClickTimeout3Test do
  @upstream "tests/page/page-click-timeout-3.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Page

  @moduletag :page

  # it.skip(mode !== 'default'): __testHookBeforeHitTarget is an in-process JS function.
  @tag skip: "not ported: __testHookBeforeHitTarget (in-process test hook)"
  test "should fail when element jumps during hit testing"

  test "should timeout waiting for hit target", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")

    Page.evaluate!(page, """
    () => {
      document.body.style.position = 'relative';
      const blocker = document.createElement('div');
      blocker.id = 'blocker';
      blocker.style.position = 'absolute';
      blocker.style.width = '400px';
      blocker.style.height = '20px';
      blocker.style.left = '0';
      blocker.style.top = '0';
      document.body.appendChild(blocker);
    }
    """)

    {:error, error} = ElementHandle.click(button, timeout: 5000)
    assert Exception.message(error) =~ "elementHandle.click: Timeout 5000ms exceeded."
    assert Exception.message(error) =~ ~s(<div id="blocker"></div> intercepts pointer events)
    assert Exception.message(error) =~ "retrying click action"
    assert Exception.message(error) =~ "waiting 500ms"
  end

  test "should still click when force but hit target is obscured", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")

    Page.evaluate!(page, """
    () => {
      document.body.style.position = 'relative';
      const blocker = document.createElement('div');
      blocker.id = 'blocker';
      blocker.style.position = 'absolute';
      blocker.style.width = '400px';
      blocker.style.height = '200px';
      blocker.style.left = '0';
      blocker.style.top = '0';
      document.body.appendChild(blocker);
    }
    """)

    ElementHandle.click!(button, force: true)
  end

  test "should report wrong hit target subtree", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")

    Page.evaluate!(page, """
    () => {
      document.body.style.position = 'relative';

      const blocker = document.createElement('div');
      blocker.id = 'blocker';
      blocker.style.position = 'absolute';
      blocker.style.width = '400px';
      blocker.style.height = '20px';
      blocker.style.left = '0';
      blocker.style.top = '0';
      document.body.appendChild(blocker);

      const inner = document.createElement('div');
      inner.id = 'inner';
      inner.style.position = 'absolute';
      inner.style.left = '0';
      inner.style.top = '0';
      inner.style.right = '0';
      inner.style.bottom = '0';
      blocker.appendChild(inner);
    }
    """)

    {:error, error} = ElementHandle.click(button, timeout: 5000)
    assert Exception.message(error) =~ "elementHandle.click: Timeout 5000ms exceeded."

    assert Exception.message(error) =~
             ~s(<div id="inner"></div> from <div id="blocker">…</div> subtree intercepts pointer events)

    assert Exception.message(error) =~ "retrying click action"
  end
end
