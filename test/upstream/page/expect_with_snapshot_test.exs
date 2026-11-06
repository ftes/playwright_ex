defmodule PlaywrightEx.Page.ExpectWithSnapshotTest do
  @upstream "tests/page/expect-with-snapshot.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page

  @moduletag :page

  describe "containment matchers print full element subtree" do
    test "toHaveText failure includes full element subtree", %{page: page} do
      Page.set_content!(page, "<section id=node><h1>Title</h1><p>Body</p></section>")
      {:error, error} = Expect.to_have_text(Page.locator(page, "#node"), "nope", timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      assert snapshot =~ "heading \"Title\""
      assert snapshot =~ "paragraph"
      assert snapshot =~ "Body"
    end

    test "toContainText failure includes full element subtree", %{page: page} do
      Page.set_content!(page, "<section id=node><h1>Title</h1><p>Body</p></section>")
      {:error, error} = Expect.to_contain_text(Page.locator(page, "#node"), "nope", timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      assert snapshot =~ "heading \"Title\""
      assert snapshot =~ "Body"
    end
  end

  describe "property matchers print only the element line" do
    test "toBeChecked failure prints just the input", %{page: page} do
      Page.set_content!(page, "<label><input id=cb type=checkbox> a checkbox</label>")
      {:error, error} = Expect.to_be_checked(Page.locator(page, "#cb"), timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      assert snapshot =~ "checkbox"
    end

    test "toHaveAttribute failure clips descendant subtree", %{page: page} do
      Page.set_content!(page, "<ul id=lst><li><h2>HeadingMarker</h2><p>BodyMarker</p></li></ul>")
      {:error, error} = Expect.to_have_attribute(Page.locator(page, "#lst"), "data-x", "yes", timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      assert snapshot =~ "list"
      assert snapshot =~ "listitem"
      # Property matcher caps depth at 1 — content inside the listitem (depth 2) must not appear.
      refute snapshot =~ "HeadingMarker"
      refute snapshot =~ "BodyMarker"
    end

    test "toHaveRole failure prints just the element line", %{page: page} do
      Page.set_content!(page, "<button id=btn>Hi<span>nested</span></button>")
      {:error, error} = Expect.to_have_role(Page.locator(page, "#btn"), "link", timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      assert snapshot =~ "button"
    end

    test "toHaveValue failure prints the input element", %{page: page} do
      Page.set_content!(page, "<input id=inp value=\"actual\">")
      {:error, error} = Expect.to_have_value(Page.locator(page, "#inp"), "expected", timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      assert snapshot =~ "textbox"
    end

    test "toHaveCSS failure prints the element line", %{page: page} do
      Page.set_content!(page, "<button id=btn style=\"color: red\">Press</button>")
      {:error, error} = Expect.to_have_css(Page.locator(page, "#btn"), "color", "rgb(0, 0, 0)", timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      assert snapshot =~ "button"
    end
  end

  describe "hidden or missing elements print full page snapshot" do
    test "toBeVisible on hidden element prints full page snapshot", %{page: page} do
      Page.set_content!(page, """
            <div id=hidden style="display: none"><span>secret</span></div>
            <main><h1>Page Heading</h1></main>
      """)

      {:error, error} = Expect.to_be_visible(Page.locator(page, "#hidden"), timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      # Page-wide context, not the empty hidden element snapshot.
      assert snapshot =~ "heading \"Page Heading\""
    end

    test "toBeVisible on missing element prints full page snapshot", %{page: page} do
      Page.set_content!(page, "<header><h1>Hello</h1></header>")
      {:error, error} = Expect.to_be_visible(Page.locator(page, "#nope"), timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      assert snapshot =~ "heading \"Hello\""
    end

    test "toHaveText on missing element prints full page snapshot", %{page: page} do
      Page.set_content!(page, "<main><h1>Hello</h1></main>")
      {:error, error} = Expect.to_have_text(Page.locator(page, "#missing"), "x", timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      assert snapshot =~ "heading \"Hello\""
    end

    test "toHaveTitle failure prints full page snapshot", %{page: page} do
      Page.set_content!(page, "<title>Right</title><main><h1>Body Heading</h1></main>")
      {:error, error} = Expect.to_have_title(page, "Wrong", timeout: 1000)
      snapshot = error.matcherResult.ariaSnapshot
      assert snapshot =~ "heading \"Body Heading\""
    end
  end

  describe "matchers that should not include an aria snapshot" do
    test "toHaveCount failure has no aria snapshot", %{page: page} do
      Page.set_content!(page, "<ul><li>a</li><li>b</li></ul>")
      {:error, error} = Expect.to_have_count(Page.locator(page, "li"), 5, timeout: 1000)
      refute Map.has_key?(error.matcherResult, :ariaSnapshot)
    end

    test "toHaveText with array has no aria snapshot", %{page: page} do
      Page.set_content!(page, "<ul><li>x</li><li>y</li></ul>")
      {:error, error} = Expect.to_have_text(Page.locator(page, "li"), ["a", "b", "c"], timeout: 1000)
      refute Map.has_key?(error.matcherResult, :ariaSnapshot)
    end

    test "toMatchAriaSnapshot failure has no extra aria snapshot", %{page: page} do
      Page.set_content!(page, "<button id=btn>Y</button>")
      {:error, error} = Expect.to_match_aria_snapshot(Page.locator(page, "#btn"), "- button \"X\"", timeout: 1000)
      refute Map.has_key?(error.matcherResult, :ariaSnapshot)
    end
  end
end
