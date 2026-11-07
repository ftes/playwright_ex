defmodule PlaywrightEx.Library.PlaywrightClientTest do
  @upstream "tests/library/playwright-client.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  # it.skip(({ mode }) => mode !== 'default');

  test "PC-001 should connect from a page and drive the same browser"
end
