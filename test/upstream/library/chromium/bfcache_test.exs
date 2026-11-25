# Copyright Microsoft Corporation. All rights reserved.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Library.Chromium.BfcacheTest do
  @upstream "tests/library/chromium/bfcache.spec.ts"
  use Playwright.UpstreamCase, async: true

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.BrowserType
  alias Playwright.Page

  @moduletag skip: if(@browser_name != "chromium", do: "upstream skip: Chromium only")

  # test.use({ launchOptions: { ...launchOptions, ignoreDefaultArgs: ['--disable-back-forward-cache'] } }):
  # a browser of its own, then contextTest's `page`.
  setup %{browser_type: browser_type} do
    browser = BrowserType.launch!(browser_type, ignore_default_args: ["--disable-back-forward-cache"])
    on_exit(fn -> Browser.close(browser) end)
    context = Browser.new_context!(browser)
    %{page: BrowserContext.new_page!(context)}
  end

  test "CR-042 bindings should work after restoring from bfcache", %{page: page, server: server} do
    Page.expose_function!(page, "add", fn a, b -> a + b end)

    Page.goto!(page, server.prefix <> "/cached/bfcached.html")
    assert Page.evaluate!(page, "window.add(1, 2)") == 3

    Page.set_content!(page, "<a href='about:blank'}>click me</a>")
    Page.click!(page, "a")

    Page.go_back!(page, wait_until: :commit)
    Page.evaluate!(page, "window.didShow")
    assert Page.evaluate!(page, "window.add(2, 3)") == 5
  end
end
