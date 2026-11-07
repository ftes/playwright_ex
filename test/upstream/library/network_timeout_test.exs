defmodule PlaywrightEx.Library.NetworkTimeoutTest do
  @upstream "tests/library/network-timeout.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  # test.skip(({ mode }) => mode !== 'default');

  test "NE-128 httpRequest should honor socketTimeout while connecting"

  test "NE-129 httpRequest should honor socketTimeout for stalled responses"

  test "NE-130 httpRequest should honor ipv4first result order"
end
