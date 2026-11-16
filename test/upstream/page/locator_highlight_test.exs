# Copyright Microsoft Corporation. All rights reserved.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Page.LocatorHighlightTest do
  @upstream "tests/page/locator-highlight.spec.ts"
  use Playwright.UpstreamCase, async: true

  alias Playwright.Expect
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.Utils

  @moduletag :page

  # it.skip(({ mode }) => mode !== 'default', ...)  -- always default mode

  test "LO-114 should highlight locator", %{page: page} do
    Page.set_content!(page, "<input type='text' />")
    Locator.highlight!(Page.locator(page, "input"))
    Expect.to_have_text!(Page.locator(page, "x-pw-tooltip"), "locator('input')")
    Expect.to_be_visible!(Page.locator(page, "x-pw-highlight"))
    box1 = Utils.round_box(Locator.bounding_box!(Page.locator(page, "input")))
    box2 = Utils.round_box(Locator.bounding_box!(Page.locator(page, "x-pw-highlight")))
    assert box1 == box2
  end
end
