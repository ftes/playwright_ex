defmodule PlaywrightEx.Library.SharedWorkerTest do
  @upstream "tests/library/shared-worker.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page

  @moduletag :page

  test "WO-026 should survive shared worker restart", %{context: context, server: server} do
    page1 = BrowserContext.new_page!(context)
    Page.goto!(page1, server.prefix <> "/shared-worker/shared-worker.html")
    assert Page.evaluate!(page1, "window.sharedWorkerResponsePromise") == "echo:hello"
    Page.close!(page1)

    page2 = BrowserContext.new_page!(context)
    Page.goto!(page2, server.prefix <> "/shared-worker/shared-worker.html")
    assert Page.evaluate!(page2, "window.sharedWorkerResponsePromise") == "echo:hello"
    Page.close!(page2)
  end
end
