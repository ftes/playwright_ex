defmodule PlaywrightEx.Page.PageStrictTest do
  @upstream "tests/page/page-strict.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "SM-001 should fail page.textContent in strict mode", %{page: page} do
    Page.set_content!(page, "<span>span1</span><div><span>target</span></div>")
    {:error, error} = Page.text_content(page, "span", strict: true)
    assert Exception.message(error) =~ "strict mode violation"
    assert Exception.message(error) =~ "1) <span>span1</span> aka getByText('span1')"
    assert Exception.message(error) =~ "2) <span>target</span> aka getByText('target')"
  end

  test "SM-002 should fail page.getAttribute in strict mode", %{page: page} do
    Page.set_content!(page, "<span>span1</span><div><span>target</span></div>")
    {:error, error} = Page.get_attribute(page, "span", "id", strict: true)
    assert Exception.message(error) =~ "strict mode violation"
  end

  test "SM-003 should fail page.fill in strict mode", %{page: page} do
    Page.set_content!(page, "<input></input><div><input></input></div>")
    {:error, error} = Page.fill(page, "input", "text", strict: true)
    assert Exception.message(error) =~ "strict mode violation"
    assert Exception.message(error) =~ "1) <input/> aka getByRole('textbox').first()"
    assert Exception.message(error) =~ "2) <input/> aka locator('div').getByRole('textbox')"
  end

  test "SM-004 should fail page.$ in strict mode", %{page: page} do
    Page.set_content!(page, "<span>span1</span><div><span>target</span></div>")
    {:error, error} = Page.query_selector(page, "span", strict: true)
    assert Exception.message(error) =~ "strict mode violation"
  end

  test "SM-005 should fail page.waitForSelector in strict mode", %{page: page} do
    Page.set_content!(page, "<span>span1</span><div><span>target</span></div>")
    {:error, error} = Page.wait_for_selector(page, "span", strict: true)
    assert Exception.message(error) =~ "strict mode violation"
  end

  test "SM-006 should fail page.dispatchEvent in strict mode", %{page: page} do
    Page.set_content!(page, "<span></span><div><span></span></div>")
    {:error, error} = Page.dispatch_event(page, "span", "click", %{}, strict: true)
    assert Exception.message(error) =~ "strict mode violation"
    assert Exception.message(error) =~ "1) <span></span> aka locator('span').first()"
    assert Exception.message(error) =~ "2) <span></span> aka locator('div span')"
  end

  test "SM-007 should properly format :nth-child() in strict mode message", %{page: page} do
    Page.set_content!(page, """
    <div>
      <div>
      </div>
      <div>
        <div>
        </div>
        <div>
        </div>
      </div>
    </div>
    <div>
      <div class='foo'>
      </div>
      <div class='foo'>
      </div>
    </div>
    """)

    {:error, error} = page |> Page.locator(".foo") |> Locator.hover()
    assert Exception.message(error) =~ "strict mode violation"
    # Second div has body > div:nth-child(2) > div:nth-child(2) selector which would be ambiguous
    # if '>' were ' '.
    assert Exception.message(error) =~ "body > div:nth-child(2) > div:nth-child(2)"
  end

  test "SM-008 should escape class names", %{page: page} do
    Page.set_content!(page, """
    <div>
      <div></div>
      <div>
        <div></div>
        <div></div>
      </div>
    </div>
    <div>
      <div class='foo bar:0'>
      </div>
      <div class='foo bar:1'>
      </div>
    </div>
    """)

    {:error, error} = page |> Page.locator(".foo") |> Locator.hover()
    assert Exception.message(error) =~ "strict mode violation"
    assert Exception.message(error) =~ ~s(<div class="foo bar:0)
    assert Exception.message(error) =~ ~s(<div class="foo bar:1)
  end

  test "SM-009 should escape tag names", %{page: page} do
    Page.set_content!(page, """
      <q:template> </q:template>
      <span>special test description</span>
      <q:template hidden="" aria-hidden="true">
        <span>special test description</span>
      </q:template>
    """)

    {:error, error} = page |> Page.get_by_text("special test description") |> Expect.to_be_visible()
    assert Exception.message(error) =~ "strict mode violation"
    assert Exception.message(error) =~ "getByText('special test description').first()"

    assert Exception.message(error) =~
             "locator('q\\\\:template').filter({ hasText: 'special test description' })"
  end

  test "SM-010 should keep the engine name for a \"text=..\" selector in strict mode", %{page: page} do
    Page.set_content!(page, "<div>..loading</div><div>..loading</div>")
    {:error, error} = page |> Page.locator("text=..loading") |> Locator.hover()
    assert Exception.message(error) =~ "strict mode violation"
    assert Exception.message(error) =~ "locator('text=..loading')"
  end
end
