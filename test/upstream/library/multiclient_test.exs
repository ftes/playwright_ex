defmodule PlaywrightEx.Library.MulticlientTest do
  @upstream "tests/library/multiclient.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  # The fixtures connect several clients to `browserType.launchServer({ _sharedBrowser: true })`
  # (a shared browser: `run-server` has no such mode).

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should connect two clients"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should fire context event on remote newContext"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should have separate default timeouts"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should receive viewport size changes"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should not allow parallel js coverage and cleanup upon disconnect"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should not allow parallel css coverage"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should unpause clock"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "last emulateMedia wins"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should chain routes"

  @tag skip: "upstream fixme: test.fixme (no reason given)"
  test "should chain routes with changed url"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should remove exposed bindings upon disconnect"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should unroute websockets"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should remove init scripts upon disconnect"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should remove locator handlers upon disconnect"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should launch persistent"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should avoid side effects upon disconnect"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "screencast should deliver cached last frame to a new client"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should stop tracing upon disconnect"
end
