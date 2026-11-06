defmodule PlaywrightEx.Client.ChannelOwnerReuseTest do
  # Not mirrored from upstream: a context re-created with the guid of a disposed one
  # (`Browser._newContextForReuse`) is a new object, as `new BrowserContext(...)` is in JS.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.Browser, as: ClientBrowser
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Selectors

  # tests/library/browsercontext-reuse.spec.ts `reusedContext` (launch scenario).
  defp reused_context(browser) do
    Api.call("browser._newContextForReuse", browser, fn ->
      ClientBrowser._disconnect_from_reused_context(browser, "reusedContext")
      ClientBrowser._new_context_for_reuse(browser, %{})
    end)
  end

  test "a reused context gets each event once, and not the listeners of the disposed one", %{browser_type: browser_type} do
    test = self()
    browser = BrowserType.launch!(browser_type)

    context = reused_context(browser)
    BrowserContext.on(context, :page, fn _ -> send(test, :old_listener) end)
    BrowserContext.new_page!(context)
    assert_received :old_listener

    context = reused_context(browser)
    BrowserContext.on(context, :page, fn _ -> send(test, :new_listener) end)
    BrowserContext.new_page!(context)

    assert_received :new_listener
    refute_received :new_listener
    refute_received :old_listener
    assert length(BrowserContext.pages(context)) == 2
    PlaywrightEx.Browser.close!(browser)
  end

  # The disposed context's anchor (the process that created it) exiting freed the rows of the
  # new one, which shares its guid: its `_onClose` found no `_browser`, so it stayed in
  # `selectors._contextsForSelectors` and the next `selectors.register` on this driver raised
  # (`setTestIdAttribute`: BadMapError on its nil `_options`).
  test "a reused context outlives the creator of the disposed one", %{
    playwright: playwright,
    browser_type: browser_type
  } do
    browser = BrowserType.launch!(browser_type)

    context =
      Task.async(fn ->
        context = reused_context(browser)
        BrowserContext.new_page!(context)
        reused_context(browser)
      end)
      |> Task.await()

    selectors = Playwright.selectors(playwright)
    contexts_for_selectors = fn -> Api.call(nil, browser, fn -> Heap.get(selectors, :_contextsForSelectors) end) end
    assert Api.call(nil, browser, fn -> Heap.get(context, :_browser) end) == browser
    assert context in contexts_for_selectors.()

    PlaywrightEx.Browser.close!(browser)
    refute context in contexts_for_selectors.()
    Selectors.set_test_id_attribute(selectors, "data-testid")
    Selectors.register!(selectors, "reusedContextCSS", "({ query() {}, queryAll() { return []; } })")
  end
end
