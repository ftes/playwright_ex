defmodule PlaywrightEx.Library.BrowsercontextFetchHappyEyeballsTest do
  @upstream "tests/library/browsercontext-fetch-happy-eyeballs.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Expect
  alias PlaywrightEx.TestServer

  @moduletag :page

  # const __testHookLookup = ...; let interceptedHostnameLookup  -- not ported: in-process test hook

  setup %{server: server} do
    # Force a new connection every time, so that we can intercept the hostname lookup.
    TestServer.set_extra_headers(server, "/simple.json", %{"Connection" => "close"})
    :ok
  end

  @tag skip: "not ported: __testHookLookup (in-process test hook)"
  test "get should work"

  @tag skip: "not ported: __testHookLookup (in-process test hook)"
  test "get should work on request fixture"

  @tag skip: "not ported: __testHookLookup (in-process test hook)"
  test "https post should work with ignoreHTTPSErrors option"

  @tag :request
  test "should work with ip6 and port as the host", %{request: request, server: server} do
    # it.skip(!!process.env.INSIDE_DOCKER, 'docker does not support IPv6 by default');
    response = APIRequestContext.get!(request, "http://[::1]:#{server.port}/simple.json")
    assert APIResponse.url(response) == "http://[::1]:#{server.port}/simple.json"
    Expect.to_be_ok!(response)
  end
end
