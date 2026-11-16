# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Library.BrowsersPathTest do
  @upstream "tests/library/browsers-path.spec.ts"
  use Playwright.UpstreamCase, async: true

  test "BP-001 should import on an unsupported platform when PLAYWRIGHT_BROWSERS_PATH=0"

  test "BP-002 should import on an unsupported platform with an explicit PLAYWRIGHT_BROWSERS_PATH"
end
