defmodule PlaywrightEx.Page.PageCacheStorageTest do
  @upstream "tests/page/page-cache-storage.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  test "CacheStorage entry should survive page.reload()", %{page: page, server: server, browser_name: browser_name} do
    # test.fail(browserName === 'webkit'): ephemeral CacheStorage is not persisted across reload in WebKit.
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    async () => {
      const cache = await caches.open('repro-cache');
      await cache.put('/meta', new Response('payload'));
    }
    """)

    Page.reload!(page)

    after_reload =
      Page.evaluate!(page, """
      async () => {
        const cache = await caches.open('repro-cache');
        const resp = await cache.match('/meta');
        return resp ? await resp.text() : null;
      }
      """)

    if browser_name == "webkit", do: refute(after_reload == "payload"), else: assert(after_reload == "payload")
  end
end
