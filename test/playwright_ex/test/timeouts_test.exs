defmodule PlaywrightEx.Test.TimeoutsTest do
  # Playwright Test's `actionTimeout`/`navigationTimeout` (none by default) on each context of the
  # test, and the test timeout's timer in its recorder. The timeout's closes and errors:
  # `PlaywrightEx.Test.EndToEndTest`.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Recorder

  setup_all do
    browser = BrowserPool.browser()
    %{browser: browser, playwright: BrowserPool.playwright(browser)}
  end

  defp defaults(owner) do
    settings = Heap.get(owner, :_timeoutSettings)
    {Heap.get(settings, :_defaultTimeout), Heap.get(settings, :_defaultNavigationTimeout)}
  end

  test "each context gets no action and navigation timeout by default, upstream's 0", ctx do
    assert defaults(Browser.new_context!(ctx.browser)) == {0, 0}
    assert defaults(Task.await(Task.async(fn -> Browser.new_context!(ctx.browser) end))) == {0, 0}

    request = APIRequest.new_context!(PlaywrightEx.Playwright.request(ctx.playwright))
    assert {0, nil} = defaults(request)
    APIRequestContext.dispose!(request)

    # The Playwright's defaults stay as they were: the driver outlives the test.
    assert Heap.get(ctx.playwright, :_defaultContextTimeout) == nil

    # A context's own setting wins.
    context = Browser.new_context!(ctx.browser)
    BrowserContext.set_default_timeout(context, 100)
    page = BrowserContext.new_page!(context)

    assert {:error, %{message: "page.waitForSelector: Timeout 100ms exceeded." <> _}} =
             Page.wait_for_selector(page, "#x")
  end

  test "a test with a timeout arms its recorder's timer, 1 s or 5% before it", ctx do
    Browser.new_context!(ctx.browser)
    assert is_reference(:sys.get_state(Recorder.lookup(self())).timer)
    assert Recorder.test_timeout_margin(60_000) == 1000
    assert Recorder.test_timeout_margin(3000) == 150
  end

  @tag timeout: :infinity
  test "a test without a timeout has no timer", ctx do
    Browser.new_context!(ctx.browser)
    assert :sys.get_state(Recorder.lookup(self())).timer == nil
  end
end
