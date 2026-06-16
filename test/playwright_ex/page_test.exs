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

  describe "close/2" do
    test "Close page", %{page: page, frame: _frame} do
      assert {:ok, _} = Page.close(page.guid, timeout: @timeout)
    end
  end

  # 1×1 red pixel PNG
  @one_by_one_png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGL5z8AAAAAA//+FDQv1AAAABklEQVQDAAMRAQSnRfifAAAAAElFTkSuQmCC"

  describe "expect_screenshot/2" do
    test "returns base64-encoded PNG in capture-only mode", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      # "iVBORw0K" is the base64 encoding of the 6-byte PNG magic header
      assert {:ok, <<"iVBORw0K", _::binary>>} =
               Page.expect_screenshot(page.guid, timeout: @timeout)
    end

    test "succeeds when actual matches baseline", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      {:ok, baseline} = Page.expect_screenshot(page.guid, timeout: @timeout)

      assert {:ok, _} = Page.expect_screenshot(page.guid, expected: baseline, timeout: @timeout)
    end

    test "returns error when actual does not match baseline", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      assert {:error,
              %{
                timed_out: false,
                custom_error_message:
                  "Expected an image 1px by 1px, received 1280px by 720px. 1 pixels (ratio 0.01 of all image pixels) are different.",
                log: _,
                diff: _,
                actual: _
              }} =
               Page.expect_screenshot(page.guid, expected: @one_by_one_png, timeout: @timeout)
    end

    test "clips screenshot to element bounding box", %{page: page, frame: frame} do
      :ok = set_html(frame.guid, "<div id='target' style='width:1px;height:1px;background:#FF0000'></div>")
      {:ok, box} = eval(frame.guid, "() => document.getElementById('target').getBoundingClientRect().toJSON()")

      clip = %{x: box["x"], y: box["y"], width: box["width"], height: box["height"]}

      assert {:ok, nil} =
               Page.expect_screenshot(page.guid, clip: clip, expected: @one_by_one_png, timeout: @timeout)
    end

    test "scopes screenshot to locator", %{page: page, frame: frame} do
      :ok = set_html(frame.guid, "<div id='target' style='width:1px;height:1px;background:#FF0000'></div>")

      assert {:ok, nil} =
               Page.expect_screenshot(page.guid,
                 locator: %{frame: %{guid: frame.guid}, selector: "#target"},
                 expected: @one_by_one_png,
                 timeout: @timeout
               )
    end

    test "accepts full_page option", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      assert {:ok, <<"iVBORw0K", _::binary>>} =
               Page.expect_screenshot(page.guid, full_page: true, timeout: @timeout)
    end

    test "is_not: true succeeds when screenshots differ", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      assert {:ok, _} =
               Page.expect_screenshot(page.guid, expected: @one_by_one_png, is_not: true, timeout: @timeout)
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
