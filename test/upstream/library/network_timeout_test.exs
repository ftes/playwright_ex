defmodule PlaywrightEx.Library.NetworkTimeoutTest do
  @upstream "tests/library/network-timeout.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  # test.skip(({ mode }) => mode !== 'default');

  test "httpRequest should honor socketTimeout while connecting"

  test "httpRequest should honor socketTimeout for stalled responses"

  test "httpRequest should honor ipv4first result order"
end
