# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Library.PlaywrightClientTest do
  @upstream "tests/library/playwright-client.spec.ts"
  use Playwright.UpstreamCase, async: true

  # it.skip(({ mode }) => mode !== 'default');

  test "PC-001 should connect from a page and drive the same browser"
end
