defmodule PlaywrightEx.Library.BrowsercontextBaseUrlTest do
  @upstream "tests/library/browsercontext-base-url.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route

  test "NA-089 should construct a new URL when a baseURL in browser.newContext is passed to page.goto @smoke",
       %{
         browser: browser,
         server: server
       } do
    context = Browser.new_context!(browser, base_url: server.prefix)
    page = BrowserContext.new_page!(context)
    assert Response.url(Page.goto!(page, "/empty.html")) == server.empty_page
    BrowserContext.close!(context)
  end

  test "NA-090 should construct a new URL when a baseURL in browser.newPage is passed to page.goto", %{
    browser: browser,
    server: server
  } do
    page = Browser.new_page!(browser, base_url: server.prefix)
    assert Response.url(Page.goto!(page, "/empty.html")) == server.empty_page
    Page.close!(page)
  end

  test "NA-091 should construct a new URL when a baseURL in browserType.launchPersistentContext is passed to page.goto",
       %{
         browser_type: browser_type,
         server: server,
         create_user_data_dir: create_user_data_dir
       } do
    user_data_dir = create_user_data_dir.()

    context =
      BrowserType.launch_persistent_context!(browser_type, user_data_dir, base_url: server.prefix)

    page = BrowserContext.new_page!(context)
    assert Response.url(Page.goto!(page, "/empty.html")) == server.empty_page
    BrowserContext.close!(context)
  end

  test "NA-092 should construct the URLs correctly when a baseURL without a trailing slash in browser.newPage is passed to page.goto",
       %{browser: browser, server: server} do
    page = Browser.new_page!(browser, base_url: server.prefix <> "/url-construction")
    assert Response.url(Page.goto!(page, "mypage.html")) == server.prefix <> "/mypage.html"
    assert Response.url(Page.goto!(page, "./mypage.html")) == server.prefix <> "/mypage.html"
    assert Response.url(Page.goto!(page, "/mypage.html")) == server.prefix <> "/mypage.html"
    Page.close!(page)
  end

  test "NA-093 should construct the URLs correctly when a baseURL with a trailing slash in browser.newPage is passed to page.goto",
       %{browser: browser, server: server} do
    page = Browser.new_page!(browser, base_url: server.prefix <> "/url-construction/")

    assert Response.url(Page.goto!(page, "mypage.html")) ==
             server.prefix <> "/url-construction/mypage.html"

    assert Response.url(Page.goto!(page, "./mypage.html")) ==
             server.prefix <> "/url-construction/mypage.html"

    assert Response.url(Page.goto!(page, "/mypage.html")) == server.prefix <> "/mypage.html"
    assert Response.url(Page.goto!(page, ".")) == server.prefix <> "/url-construction/"
    assert Response.url(Page.goto!(page, "/")) == server.prefix <> "/"
    Page.close!(page)
  end

  test "NA-094 should not construct a new URL when valid URLs are passed", %{
    browser: browser,
    server: server
  } do
    page = Browser.new_page!(browser, base_url: "http://microsoft.com")
    assert Response.url(Page.goto!(page, server.empty_page)) == server.empty_page

    Page.goto!(page, "data:text/html,Hello world")
    assert Page.evaluate!(page, "() => window.location.href") == "data:text/html,Hello world"

    Page.goto!(page, "about:blank")
    assert Page.evaluate!(page, "() => window.location.href") == "about:blank"
    Page.close!(page)
  end

  test "NA-095 should be able to match a URL relative to its given URL with urlMatcher", %{
    browser: browser,
    server: server
  } do
    page = Browser.new_page!(browser, base_url: server.prefix <> "/foobar/")
    Page.goto!(page, "/kek/index.html")
    Page.wait_for_url!(page, "/kek/index.html")
    assert Page.url(page) == server.prefix <> "/kek/index.html"

    Page.route!(page, "./kek/index.html", fn route ->
      Route.fulfill!(route, body: "base-url-matched-route")
    end)

    request = Page.wait_for_request(page, "./kek/index.html")
    response = Page.wait_for_response(page, "./kek/index.html")
    Page.goto!(page, "./kek/index.html")
    request = Promise.await!(request)
    response = Promise.await!(response)
    assert Request.url(request) == server.prefix <> "/foobar/kek/index.html"
    assert Response.url(response) == server.prefix <> "/foobar/kek/index.html"
    assert Response.body!(response) == "base-url-matched-route"
    Page.close!(page)
  end

  test "NA-096 should not construct a new URL with baseURL when a glob was used", %{
    browser: browser,
    server: server
  } do
    page = Browser.new_page!(browser, base_url: server.prefix <> "/foobar/")
    Page.goto!(page, "./kek/index.html")
    Page.wait_for_url!(page, "**/foobar/kek/index.html")
    Page.close!(page)
  end
end
