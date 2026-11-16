# Copyright (c) Microsoft Corporation. All rights reserved.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Library.BrowsercontextFetchHappyEyeballsTest do
  @upstream "tests/library/browsercontext-fetch-happy-eyeballs.spec.ts"
  use Playwright.UpstreamCase, async: true

  alias Playwright.APIRequestContext
  alias Playwright.APIResponse
  alias Playwright.Expect
  alias Playwright.TestServer

  @moduletag :page

  # const __testHookLookup = ...; let interceptedHostnameLookup  -- not ported: in-process test hook

  setup %{server: server} do
    # Force a new connection every time, so that we can intercept the hostname lookup.
    TestServer.set_extra_headers(server, "/simple.json", %{"Connection" => "close"})
    :ok
  end

  test "FE-185 get should work"

  test "FE-186 get should work on request fixture"

  test "FE-187 https post should work with ignoreHTTPSErrors option"

  @tag :request
  @tag skip: if(System.get_env("INSIDE_DOCKER", "") != "", do: "upstream skip: docker does not support IPv6 by default")
  test "FE-188 should work with ip6 and port as the host", %{request: request, server: server} do
    response = APIRequestContext.get!(request, "http://[::1]:#{server.port}/simple.json")
    assert APIResponse.url(response) == "http://[::1]:#{server.port}/simple.json"
    Expect.to_be_ok!(response)
  end
end
