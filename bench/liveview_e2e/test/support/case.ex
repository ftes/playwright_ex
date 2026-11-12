defmodule LiveViewE2E.Case do
  @moduledoc """
  `test-fixtures.js` and the `projects` of `playwright.config.js`.

  A module runs once per project (`parameterize:`), with `browser_name` in the context as
  Playwright Test's `browserName` fixture. `BROWSERS=chromium mix test` runs one project.

  The `page` fixture's checks (no unhandled page errors unless `ignore_js_errors`, no
  `[data-phx-skip]` left) run after the test, in an `on_exit`, as the fixture's teardown.
  `@tag ignore_js_errors: true` (or `@describetag`, `@moduletag`) is `test.use({ ignoreJSErrors: true })`.

  `POOL=exclusive` gives every project a browser per module, as Playwright Test's workers;
  the default shares the Chromium and WebKit browsers and gives Firefox exclusive ones, as the
  PlaywrightEx guide advises.
  """

  alias PlaywrightEx.{Browser, BrowserContext, Expect, Page, Playwright}
  alias PlaywrightEx.Test.BrowserPool

  @devices %{chromium: "Desktop Chrome", firefox: "Desktop Firefox", webkit: "Desktop Safari"}

  def projects do
    "BROWSERS"
    |> System.get_env("chromium,firefox,webkit")
    |> String.split(",", trim: true)
    |> Enum.map(&%{browser_name: String.to_existing_atom(&1)})
  end

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case,
          Keyword.merge([async: true, parameterize: LiveViewE2E.Case.projects()], unquote(opts))

      use PlaywrightEx.Test

      import LiveViewE2E.Utils

      alias PlaywrightEx.{
        APIRequestContext,
        APIResponse,
        Browser,
        BrowserContext,
        ConsoleMessage,
        Dialog,
        Download,
        Expect,
        Keyboard,
        Locator,
        Mouse,
        Page,
        Promise,
        Request,
        Route,
        WebSocketRoute
      }

      alias PlaywrightEx.Test.BrowserPool

      setup_all ctx do
        LiveViewE2E.Case.browser_fixture(ctx)
      end

      setup ctx do
        LiveViewE2E.Case.page_fixture(ctx)
      end
    end
  end

  @doc false
  def browser_fixture(%{browser_name: name}) do
    browser =
      if name == :firefox or System.get_env("POOL") == "exclusive",
        do: BrowserPool.exclusive(browser_name: name),
        else: BrowserPool.shared(browser_name: name)

    %{browser: browser}
  end

  @doc false
  def page_fixture(%{browser: browser, browser_name: name} = ctx) do
    context = Browser.new_context!(browser, device(browser, name))
    page = BrowserContext.new_page!(context)

    # pageChecks: the errors outlive the test process, for the teardown in on_exit.
    {:ok, errors} = Agent.start(fn -> [] end)
    Page.on(page, :page_error, fn error -> Agent.update(errors, &(&1 ++ [error])) end)
    ignore_js_errors = Map.get(ctx, :ignore_js_errors, false)

    ExUnit.Callbacks.on_exit(fn ->
      unhandled_errors = Agent.get(errors, & &1)
      Agent.stop(errors)

      if not ignore_js_errors do
        ExUnit.Assertions.assert(
          unhandled_errors == [],
          "Detected an unhandled JavaScript Error!"
        )
      end

      page |> Page.locator("[data-phx-skip]") |> Expect.to_have_count!(0)
    end)

    %{context: context, page: page}
  end

  # `devices["Desktop Chrome"]` and so on; `defaultBrowserType` picks the project's browser.
  defp device(browser, name) do
    key = {__MODULE__, :device, name}

    case :persistent_term.get(key, nil) do
      nil ->
        device =
          browser
          |> BrowserPool.playwright()
          |> Playwright.devices()
          |> Map.fetch!(@devices[name])
          |> Map.delete(:default_browser_type)
          |> Enum.to_list()

        :persistent_term.put(key, device)
        device

      device ->
        device
    end
  end

  @doc "Playwright Test's `request` fixture: a request context with the config's `use`."
  def request_fixture(%{browser: browser}) do
    browser
    |> BrowserPool.playwright()
    |> Playwright.request()
    |> PlaywrightEx.APIRequest.new_context!()
  end
end
