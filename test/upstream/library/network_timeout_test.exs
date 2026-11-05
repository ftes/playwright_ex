defmodule PlaywrightEx.Library.NetworkTimeoutTest do
  @upstream "tests/library/network-timeout.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  # test.skip(({ mode }) => mode !== 'default');

  @tag skip: "not ported: utils.httpRequest (playwright-core server-side network utils, not the client)"
  test "httpRequest should honor socketTimeout while connecting"

  @tag skip: "not ported: utils.httpRequest (playwright-core server-side network utils, not the client)"
  test "httpRequest should honor socketTimeout for stalled responses"

  @tag skip: "not ported: utils.httpRequest and Node's dns module (playwright-core server-side network utils)"
  test "httpRequest should honor ipv4first result order"
end
