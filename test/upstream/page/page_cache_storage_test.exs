defmodule PlaywrightEx.Page.PageCacheStorageTest do
  @upstream "tests/page/page-cache-storage.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  test "ST-032 CacheStorage entry should survive page.reload()", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/41618' }
    # test.fail(browserName === 'webkit', 'Ephemeral CacheStorage is not persisted across reload in WebKit, consistent with Safari')
    expected_failure(browser_name == "webkit", fn ->
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

      assert after_reload == "payload"
    end)
  end
end
