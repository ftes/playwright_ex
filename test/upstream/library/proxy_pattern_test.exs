defmodule PlaywrightEx.Library.ProxyPatternTest do
  @upstream "tests/library/proxy-pattern.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @tag skip: "not ported: utils.parsePattern (server-side packages/utils/socksProxy.ts)"
  test "socks proxy patter matcher"
end
