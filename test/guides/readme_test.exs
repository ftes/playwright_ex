defmodule Playwright.Guides.ReadmeTest do
  # The snippet of `README.md`, routed instead of the network. Not async: it starts the
  # supervisor under its default name.
  use ExUnit.Case, async: false

  alias Playwright.Browser
  alias Playwright.BrowserType
  alias Playwright.Expect
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.Request
  alias Playwright.Route
  alias Playwright.TestBrowser

  test "example" do
    {:ok, _} = start_supervised(Playwright.Supervisor)
    browser = BrowserType.launch!(TestBrowser.browser_type(Playwright.instance()))
    page = Browser.new_page!(browser)

    Page.route!(page, "https://elixir-lang.org/**", fn route, request ->
      title = if String.ends_with?(Request.url(request), "/install.html"), do: "Install", else: "Elixir"

      Route.fulfill(route,
        body: ~s(<title>#{title}</title><a href="/install.html">Install</a>),
        content_type: "text/html"
      )
    end)

    Page.goto!(page, "https://elixir-lang.org/")
    Page.get_by_role(page, :link, name: "Install") |> Locator.click!()
    Expect.to_have_title!(page, ~r/Install/)
    Browser.close!(browser)
  end
end
