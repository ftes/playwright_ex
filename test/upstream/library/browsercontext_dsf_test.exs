# Copyright (c) Microsoft Corporation. All rights reserved.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Library.BrowsercontextDsfTest do
  @upstream "tests/library/browsercontext-dsf.spec.ts"
  use Playwright.UpstreamCase, async: true

  alias Playwright.BrowserContext
  alias Playwright.Page
  alias Playwright.Promise
  alias Playwright.Request

  test "DV-009 should fetch lodpi assets @smoke", %{context_factory: context_factory, server: server} do
    context = context_factory.(device_scale_factor: 1)
    page = BrowserContext.new_page!(context)
    request = Page.wait_for_request(page, "**/image*")
    Page.goto!(page, server.prefix <> "/highdpi.html")
    request = Promise.await!(request)
    assert Request.url(request) =~ "image1x"
  end

  test "DV-010 should fetch hidpi assets", %{context_factory: context_factory, server: server} do
    context = context_factory.(device_scale_factor: 2)
    page = BrowserContext.new_page!(context)
    request = Page.wait_for_request(page, "**/image*")
    Page.goto!(page, server.prefix <> "/highdpi.html")
    request = Promise.await!(request)
    assert Request.url(request) =~ "image2x"
  end
end
