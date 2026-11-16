# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Library.SharedWorkerTest do
  @upstream "tests/library/shared-worker.spec.ts"
  use Playwright.UpstreamCase, async: true

  alias Playwright.BrowserContext
  alias Playwright.Page

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
