defmodule PlaywrightEx.Library.Events.MethodNamesTest do
  @upstream "tests/library/events/method-names.spec.ts"
  # Deviation: plain ExUnit case, these specs test the client EventEmitter without a browser.
  use ExUnit.Case, async: true

  @moduletag upstream: @upstream

  @tag skip: "not ported: JS prototype and function identity (ee.on === ee.addListener, fn.name)"
  test "EventEmitter prototype test"
end
