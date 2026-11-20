defmodule Playwright.GetByRoleTest do
  # Elixir only: `getByRole` and `toHaveRole` take any string, its atoms are `AriaRole`'s (`Mix.Playwright.ApiRules`).
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserType
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.TestBrowser

  setup_all do
    start_supervised!({Playwright.Supervisor, name: __MODULE__})
    browser = BrowserType.launch!(TestBrowser.browser_type(Playwright.instance(__MODULE__)))
    on_exit(fn -> Browser.close(browser) end)
    %{browser: browser}
  end

  test "a string is any role the browser matches, also one AriaRole lacks", %{browser: browser} do
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<section aria-label=s><p>a <mark>hi</mark></p></section>")

    assert page |> Page.get_by_role("mark") |> Locator.text_content!() == "hi"
    assert page |> Page.get_by_role(:region) |> Locator.get_by_role("mark") |> Locator.text_content!() == "hi"
    assert page |> Page.get_by_role("region") |> Locator.count!() == 1
  end

  test "to_have_role takes such a string too", %{browser: browser} do
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<p>a <mark>hi</mark></p>")

    assert page |> Page.locator("mark") |> Playwright.Expect.to_have_role!("mark") == :ok
  end

  test "an atom is one of AriaRole's", %{browser: browser} do
    page = Browser.new_page!(browser)

    assert_raise ArgumentError, ~r/^page\.getByRole: invalid value :mark for role, expected one of :alert, /, fn ->
      Page.get_by_role(page, :mark)
    end
  end
end
