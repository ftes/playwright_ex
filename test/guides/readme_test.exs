defmodule PlaywrightEx.Guides.ReadmeTest do
  # The snippet of `README.md`, routed instead of the network. Not async: it starts the
  # supervisor under its default name.
  use ExUnit.Case, async: false

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestBrowser

  test "example" do
    {:ok, _} = start_supervised(PlaywrightEx.Supervisor)
    browser = BrowserType.launch!(TestBrowser.browser_type(PlaywrightEx.playwright()))
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
