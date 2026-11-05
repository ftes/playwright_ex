defmodule PlaywrightEx.Library.Events.NumArgsTest do
  @upstream "tests/library/events/num-args.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @tag skip: "not ported: EventEmitter.emit with multiple args (single arg)"
  test "should work"
end
