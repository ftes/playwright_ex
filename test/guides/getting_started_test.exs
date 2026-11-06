defmodule PlaywrightEx.Guides.GettingStartedTest do
  # The snippets of `guides/introduction/getting-started.md`, routed instead of the network. Not
  # async: the first script starts the supervisor under its default name, and the logging
  # snippet sets a global level.
  use ExUnit.Case, async: false

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestBrowser

  @moduletag :tmp_dir

  defp serve(target, html) do
    route = fn route -> Route.fulfill(route, body: html, content_type: "text/html") end

    case target do
      %Page{} -> Page.route!(target, "**/*", route)
      %BrowserContext{} -> BrowserContext.route!(target, "**/*", route)
    end
  end

  test "supervision tree" do
    children = [
      {PlaywrightEx.Supervisor, name: MyApp.Playwright}
    ]

    {:ok, _} = start_supervised(%{id: MyApp, start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}})
    playwright = PlaywrightEx.playwright(MyApp.Playwright)
    assert %PlaywrightEx.Playwright{} = playwright
  end

  test "first script (default supervisor name)", %{tmp_dir: tmp_dir} do
    {:ok, _} = start_supervised(PlaywrightEx.Supervisor)
    # The guide uses `Playwright.chromium()`; the suite runs the browser under test.
    browser = PlaywrightEx.playwright() |> TestBrowser.browser_type() |> BrowserType.launch!()
    page = Browser.new_page!(browser)
    serve(page, "<title>Playwright</title>")
    Page.goto!(page, "https://playwright.dev/")
    assert Page.title!(page) == "Playwright"
    path = Path.join(tmp_dir, "example.png")
    Page.screenshot!(page, path: path)
    assert File.exists?(path)

    context = Browser.new_context!(browser, base_url: "http://localhost:4000")
    serve(context, "<title>Home</title>")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/")
    assert Page.url(page) == "http://localhost:4000/"

    BrowserContext.set_default_timeout(context, 5_000)
    BrowserContext.set_default_navigation_timeout(context, 10_000)
    BrowserContext.close!(context)

    Browser.close!(browser)
  end

  test "headed (compiled, not run: the suite stays headless)" do
    headed = fn chromium -> BrowserType.launch!(chromium, headless: false, slow_mo: 50) end
    assert is_function(headed, 1)
  end

  test "logging" do
    on_exit(fn -> Logger.delete_application_level(:playwright_ex) end)
    assert :ok = Logger.put_application_level(:playwright_ex, :info)
  end
end
