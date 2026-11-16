# Copyright 2018 Google Inc. All rights reserved.
# Modifications copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule PlaywrightEx.Page.PageClickDuringNavigationTest do
  @upstream "tests/page/page-click-during-navigation.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @moduletag :page

  test "CL-109 should not fail with internal error upon navigation"
end
