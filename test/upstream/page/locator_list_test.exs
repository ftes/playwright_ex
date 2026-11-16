# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Page.LocatorListTest do
  @upstream "tests/page/locator-list.spec.ts"
  use Playwright.UpstreamCase, async: true

  alias Playwright.Locator
  alias Playwright.Page

  @moduletag :page

  test "LO-126 locator.all should work", %{page: page} do
    Page.set_content!(page, "<div><p>A</p><p>B</p><p>C</p></div>")
    texts = for p <- Locator.all!(Page.locator(page, "div >> p")), do: Locator.text_content!(p)
    assert texts == ["A", "B", "C"]
  end
end
