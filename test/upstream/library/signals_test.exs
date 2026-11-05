defmodule PlaywrightEx.Library.SignalsTest do
  @upstream "tests/library/signals.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  # All tests drive a `launchServer` child process (signals, temp dir, exit codes).

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should close the browser when the node process closes"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should remove temp dir on process.exit"

  describe "signals" do
    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should report browser close signal 2"

    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should close the browser on SIGINT"

    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should close the browser on SIGTERM"

    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should close the browser on SIGHUP"

    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should kill the browser on double SIGINT and remove temp dir"

    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should kill the browser on SIGINT + SIGTERM"

    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should kill the browser on SIGTERM + SIGINT"

    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should not prevent default SIGTERM handling after browser close"
  end
end
