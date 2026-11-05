defmodule PlaywrightEx.Library.PlaywrightClientTest do
  @upstream "tests/library/playwright-client.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  # it.skip(({ mode }) => mode !== 'default');

  @tag skip: "not ported: packages/playwright-client browser bundle (lib/index.mjs) is not built in the upstream cache"
  test "should connect from a page and drive the same browser"
end
