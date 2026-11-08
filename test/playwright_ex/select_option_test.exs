defmodule PlaywrightEx.SelectOptionTest do
  # Elixir only: `valueOrLabel` in an option map (`Mix.PlaywrightEx.ApiRules`).
  use ExUnit.Case, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestBrowser

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    browser = BrowserType.launch!(TestBrowser.browser_type(PlaywrightEx.playwright(__MODULE__)))
    on_exit(fn -> Browser.close(browser) end)
    %{browser: browser}
  end

  test "a list mixes matches by value or label with an index", %{browser: browser} do
    page = Browser.new_page!(browser)

    Page.set_content!(page, """
    <select multiple>
      <option value="r">Red</option>
      <option value="g">Green</option>
      <option value="b">Blue</option>
    </select>
    """)

    assert Page.select_option!(page, "select", [%{valueOrLabel: "Red"}, %{valueOrLabel: "g"}, %{index: 2}]) ==
             ["r", "g", "b"]
  end

  test "a single option map takes valueOrLabel", %{browser: browser} do
    page = Browser.new_page!(browser)
    Page.set_content!(page, ~s(<select><option value="r">Red</option><option value="g">Green</option></select>))

    assert Page.select_option!(page, "select", %{valueOrLabel: "Green"}) == ["g"]
  end
end
