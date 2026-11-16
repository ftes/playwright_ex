# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule PlaywrightEx.Page.PageLeaksTest do
  @upstream "tests/page/page-leaks.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @moduletag :page

  test "LE-001 click should not leak"

  test "LE-002 fill should not leak"

  test "LE-003 expect should not leak"

  test "LE-004 waitFor should not leak"
end
