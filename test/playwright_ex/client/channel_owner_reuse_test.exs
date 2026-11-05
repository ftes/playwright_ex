defmodule PlaywrightEx.Client.ChannelOwnerReuseTest do
  # Not mirrored from upstream: a context re-created with the guid of a disposed one
  # (`Browser._newContextForReuse`) is a new object, as `new BrowserContext(...)` is in JS.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.Browser, as: ClientBrowser
  alias PlaywrightEx.Runtime.Api

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
end
