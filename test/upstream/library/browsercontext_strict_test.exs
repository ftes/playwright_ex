defmodule PlaywrightEx.Library.BrowsercontextStrictTest do
  @upstream "tests/library/browsercontext-strict.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  test "SM-011 should not fail page.textContent in non-strict mode", %{page: page} do
    Page.set_content!(page, "<span>span1</span><div><span>target</span></div>")
    assert Page.text_content!(page, "span", strict: false) == "span1"
  end

  describe "strict context mode" do
    # it.use({ contextOptions: { ...contextOptions, strictSelectors: true } })
    setup %{context_factory: context_factory} do
      context = context_factory.(strict_selectors: true)
      %{context: context, page: PlaywrightEx.BrowserContext.new_page!(context)}
    end

    test "SM-012 should fail page.textContent in strict mode", %{page: page} do
      Page.set_content!(page, "<span>span1</span><div><span>target</span></div>")
      {:error, error} = Page.text_content(page, "span")
      assert Exception.message(error) =~ "strict mode violation"
    end

    test "SM-013 should fail page.click in strict mode", %{page: page} do
      Page.set_content!(page, "<button>button1</button><button>target</button>")
      {:error, error} = Page.click(page, "button")
      assert Exception.message(error) =~ "strict mode violation"
    end

    test "SM-014 should opt out of strict mode", %{page: page} do
      Page.set_content!(page, "<span>span1</span><div><span>target</span></div>")
      assert Page.text_content!(page, "span", strict: false) == "span1"
    end
  end
end
