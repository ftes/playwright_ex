defmodule PlaywrightEx.Library.Events.CheckListenerLeaksTest do
  @upstream "tests/library/events/check-listener-leaks.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @tag skip: "not ported: EventEmitter.setMaxListeners (leak warnings)"
  test "defaultMaxListeners"

  @tag skip: "not ported: EventEmitter.defaultMaxListeners (leak warnings)"
  test "process-wide"

  @tag skip: "not ported: EventEmitter.setMaxListeners (leak warnings)"
  test "_maxListeners still has precedence over defaultMaxListeners"
end
