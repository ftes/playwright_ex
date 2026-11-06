defmodule PlaywrightEx.Library.BrowsercontextDsfTest do
  @upstream "tests/library/browsercontext-dsf.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request

  test "should fetch lodpi assets @smoke", %{context_factory: context_factory, server: server} do
    context = context_factory.(device_scale_factor: 1)
    page = BrowserContext.new_page!(context)
    request = Page.wait_for_request(page, "**/image*")
    Page.goto!(page, server.prefix <> "/highdpi.html")
    request = Promise.await!(request)
    assert Request.url(request) =~ "image1x"
  end

  test "should fetch hidpi assets", %{context_factory: context_factory, server: server} do
    context = context_factory.(device_scale_factor: 2)
    page = BrowserContext.new_page!(context)
    request = Page.wait_for_request(page, "**/image*")
    Page.goto!(page, server.prefix <> "/highdpi.html")
    request = Promise.await!(request)
    assert Request.url(request) =~ "image2x"
  end
end
