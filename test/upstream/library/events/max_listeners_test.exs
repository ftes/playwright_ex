defmodule PlaywrightEx.Library.Events.MaxListenersTest do
  @upstream "tests/library/events/max-listeners.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @tag skip: "not ported: EventEmitter.setMaxListeners"
  test "emit maxListeners on e"
end
