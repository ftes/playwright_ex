defmodule PlaywrightEx.Library.PageEventCrashTest do
  @upstream "tests/library/page-event-crash.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.TestServer

  @moduletag :page

  # webkit, firefox: toImpl(page).delegate._session.send('Page.crash')
  if System.get_env("BROWSER", "chromium") != "chromium",
    do: @moduletag(skip: "not ported: toImpl (crash via the server-side page session)")

  # Upstream skips chromium on ubuntu24.04 ('never dispatches the crash event'); CI's ubuntu-latest
  # (24.04) passes these tests, so they run there.
  # test.beforeEach: test.skip(browserName === 'chromium' && utils.hostPlatform.startsWith('ubuntu24.04'))
  # test.beforeEach: test.skip(webkit && debian13 / webkit-wsl)  -- moot: webkit is skipped above
  # test.beforeEach: test.slow(platform === 'linux' && browserName === 'webkit', ...)
  if System.get_env("BROWSER", "chromium") == "webkit" and match?({:unix, :linux}, :os.type()),
    do: @moduletag(timeout: @slow_timeout)

  # The `crash` fixture: page.goto('chrome://crash').catch(e => {})
  defp crash(page), do: Task.start(fn -> Page.goto(page, "chrome://crash") end)

  test "should emit crash event when page crashes", %{page: page} do
    Page.set_content!(page, "<div>This page should crash</div>")
    me = self()
    Page.on(page, :crash, &send(me, {:crash, &1}))
    crash(page)
    assert_receive {:crash, crashed_page}, 10_000
    assert crashed_page == page
  end

  test "should throw on any action after page crashes", %{page: page, server: server, browser_name: browser_name} do
    Page.set_content!(page, "<div>This page should crash</div>")
    crashed = Page.wait_for_event(page, :crash)
    crash(page)
    Promise.await!(crashed)

    expect_crash_error = fn result ->
      assert {:error, error} = result, "action should reject after crash"
      message = Exception.message(error)
      # In Firefox, crashed page is sometimes "closed".
      if browser_name == "firefox",
        do: assert(String.contains?(message, "has been closed") or String.contains?(message, "crashed"), message),
        else: assert(message =~ "crashed")
    end

    expect_crash_error.(Page.evaluate(page, "() => {}"))
    expect_crash_error.(Page.goto(page, server.empty_page))
    expect_crash_error.(Page.reload(page))
  end

  test "expect should not hang when page crashed", %{page: page} do
    expect_promise = Task.async(fn -> Expect.to_be_visible(Page.get_by_text(page, "child")) end)
    crash(page)
    assert {:error, _} = Task.await(expect_promise, :infinity)
  end

  test "should cancel waitForEvent when page crashes", %{page: page} do
    Page.set_content!(page, "<div>This page should crash</div>")
    promise = Page.wait_for_event(page, :response)
    crash(page)
    {:error, error} = Promise.await(promise)
    assert Exception.message(error) =~ "Page crashed"
  end

  test "should cancel navigation when page crashes", %{server: server, page: page} do
    Page.set_content!(page, "<div>This page should crash</div>")
    TestServer.set_route(server, "/one-style.css", fn _conn -> Process.sleep(:infinity) end)
    navigation = Page.wait_for_navigation(page, wait_until: :domcontentloaded)
    promise = Task.async(fn -> Page.goto(page, server.prefix <> "/one-style.html") end)
    Promise.await!(navigation)
    crash(page)
    {:error, error} = Task.await(promise, :infinity)
    assert Exception.message(error) =~ "page.goto: Page crashed"
  end

  test "should be able to close context when page crashes", %{page: page} do
    # test.skip(isAndroid)  -- Android is not supported
    Page.set_content!(page, "<div>This page should crash</div>")
    crashed = Page.wait_for_event(page, :crash)
    crash(page)
    Promise.await!(crashed)
    BrowserContext.close!(Page.context(page))
  end

  test "should be able to close page after crash", %{page: page} do
    Page.set_content!(page, "<div>This page should crash</div>")
    crashed = Page.wait_for_event(page, :crash)
    crash(page)
    Promise.await!(crashed)
    # Give the browser a chance to erroneously "close" the crashed page.
    Process.sleep(3000)
    assert Page.is_closed(page) == false
    assert BrowserContext.pages(Page.context(page)) == [page]
    Page.close!(page)
    assert Page.is_closed(page) == true
    assert BrowserContext.pages(Page.context(page)) == []
  end

  @tag skip: "upstream fixme: test.fixme (no reason given)"
  test "should reject in-flight worker.evaluate when page crashes"
end
