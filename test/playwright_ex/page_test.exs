defmodule PlaywrightEx.PageTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page

  describe "bring_to_front/2" do
    test "activates pages without protocol errors", %{browser_context: browser_context, page: page} do
      {:ok, second_page} = BrowserContext.new_page(browser_context.guid, timeout: @timeout)

      assert {:ok, _} = Frame.goto(page.main_frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, _} = Frame.goto(second_page.main_frame.guid, url: "about:blank", timeout: @timeout)

      assert {:ok, _} = Page.bring_to_front(page.guid, timeout: @timeout)
      assert {:ok, _} = Page.bring_to_front(second_page.guid, timeout: @timeout)
    end
  end

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

  describe "expect_url/2" do
    test "matches current URL with string expectation", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank#current", timeout: @timeout)
      assert {:ok, true} = Page.expect_url(page.guid, url: "about:blank#current", timeout: @timeout)
    end

    test "matches current URL with regex expectation", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank#regex-123", timeout: @timeout)
      assert {:ok, true} = Page.expect_url(page.guid, url: ~r/about:blank#regex-\d+/, timeout: @timeout)
    end

    test "supports negated expectation", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank#foo", timeout: @timeout)
      assert {:ok, true} = Page.expect_url(page.guid, url: "about:blank#bar", is_not: true, timeout: @timeout)
    end

    test "negated string expectation waits until URL changes", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank#stay", timeout: @timeout)

      eval(frame.guid, """
      () => {
        setTimeout(() => { window.location.hash = '#moved'; }, 100);
      }
      """)

      assert {:ok, true} = Page.expect_url(page.guid, url: "about:blank#stay", is_not: true, timeout: @timeout)
    end

    test "negated string expectation returns false on timeout", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank#unchanged", timeout: @timeout)
      assert {:ok, false} = Page.expect_url(page.guid, url: "about:blank#unchanged", is_not: true, timeout: 50)
    end

    test "uses waiter pattern for predicate expectations", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      eval(frame.guid, """
      () => {
        setTimeout(() => { window.location.hash = '#predicate'; }, 100);
      }
      """)

      predicate = fn uri -> uri.fragment == "predicate" end
      assert {:ok, true} = Page.expect_url(page.guid, url: predicate, timeout: @timeout)
    end
  end
end
