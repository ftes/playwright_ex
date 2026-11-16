# Copyright Microsoft Corporation. All rights reserved.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule PlaywrightEx.Library.ProxyPatternTest do
  @upstream "tests/library/proxy-pattern.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  test "PR-040 socks proxy patter matcher"
end
