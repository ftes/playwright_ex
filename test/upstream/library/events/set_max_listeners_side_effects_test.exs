defmodule PlaywrightEx.Library.Events.SetMaxListenersSideEffectsTest do
  @upstream "tests/library/events/set-max-listeners-side-effects.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @tag skip: "not ported: EventEmitter.setMaxListeners (no leak warnings) and the private `_events` field"
  test "set max listeners test"
end
