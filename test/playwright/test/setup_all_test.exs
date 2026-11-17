defmodule Playwright.Test.SetupAllTest do
  # The contexts of a module's `setup_all`, as upstream's `browser.newContext()` in `beforeAll`,
  # which gets the `all-hooks-included` fixtures: the context defaults, the config's
  # `context_options` and timeouts, merged under the call's options. Sync, so the config's
  # `base_url` here reaches no other module.
  use ExUnit.Case, async: false

  alias Playwright.APIRequest
  alias Playwright.APIRequestContext
  alias Playwright.APIResponse
  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Page
  alias Playwright.Runtime.Heap
  alias Playwright.Test.BrowserPool
  alias Playwright.TestServer

  # Before `use Playwright.Test`, whose `setup_all` reads the config.
  setup_all do
    server = TestServer.server(start_supervised!({TestServer, dir_path: System.tmp_dir!()}))
    TestServer.set_content(server, "/", "<p>home</p>", "text/html")
    TestServer.set_content(server, "/api", ~s({"ok": true}), "application/json")

    config = Application.get_env(:playwright, :test)
    on_exit(fn -> Application.put_env(:playwright, :test, config) end)

    Application.put_env(
      :playwright,
      :test,
      Keyword.merge(config,
        context_options: [base_url: server.prefix, locale: "de-DE"],
        action_timeout: 4321,
        navigation_timeout: 5432
      )
    )

    %{server: server}
  end

  use Playwright.Test

  setup_all do
    browser = BrowserPool.browser()
    playwright = BrowserPool.playwright(browser)

    open = fn options ->
      context = Browser.new_context!(browser, options)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, "/")
      %{context: context, page: page}
    end

    shared = open.([])
    own = open.(locale: "fr-FR")
    # A process of the `setup_all`'s, through `$callers`.
    spawned = Task.await(Task.async(fn -> open.([]) end))

    request = APIRequest.new_context!(Playwright.request(playwright))

    on_exit(fn ->
      for %{context: context} <- [shared, own, spawned], do: BrowserContext.close!(context)
      APIRequestContext.dispose!(request)
    end)

    %{shared: shared, own: own, spawned: spawned, request: request}
  end

  defp language(%{page: page}), do: Page.evaluate!(page, "navigator.language")

  defp timeouts(owner) do
    settings = Heap.get(owner, :_timeoutSettings)
    {Heap.get(settings, :_defaultTimeout), Heap.get(settings, :_defaultNavigationTimeout)}
  end

  test "a context of setup_all gets the defaults and the config's context_options, base_url too", ctx do
    assert Page.url(ctx.shared.page) == ctx.server.prefix <> "/"
    assert Page.text_content!(ctx.shared.page, "p") == "home"
    assert language(ctx.shared) == "de-DE"
    assert Page.viewport_size(ctx.shared.page) == %{width: 1280, height: 720}
  end

  test "an option the call gives wins", ctx do
    assert language(ctx.own) == "fr-FR"
    assert Page.url(ctx.own.page) == ctx.server.prefix <> "/"
  end

  test "a context of a process of setup_all's ($callers) gets them too", ctx do
    assert language(ctx.spawned) == "de-DE"
    assert Page.url(ctx.spawned.page) == ctx.server.prefix <> "/"
  end

  test "a request context of setup_all gets the base_url and the action timeout", ctx do
    assert APIResponse.status(APIRequestContext.get!(ctx.request, "/api")) == 200
    assert {4321, nil} = timeouts(ctx.request)
  end

  test "a context of setup_all gets the config's timeouts", ctx do
    assert timeouts(ctx.shared.context) == {4321, 5432}
  end
end
