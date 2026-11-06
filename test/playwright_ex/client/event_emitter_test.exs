defmodule PlaywrightEx.Client.EventEmitterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PlaywrightEx.Client.EventEmitter

  test "warns once when a type exceeds the max listeners (default 10); 0 means no limit" do
    emitter = EventEmitter.new()
    assert EventEmitter.get_max_listeners(emitter) == 10

    log = capture_log(fn -> for i <- 1..12, do: EventEmitter.on(emitter, "foo", fn _ -> i end) end)

    assert log =~
             "MaxListenersExceededWarning: Possible EventEmitter memory leak detected. 11 foo listeners added. Use emitter.setMaxListeners() to increase limit"

    refute log =~ "12 foo listeners"

    emitter = EventEmitter.set_max_listeners(EventEmitter.new(), 0)
    refute capture_log(fn -> for i <- 1..12, do: EventEmitter.on(emitter, "foo", fn _ -> i end) end) =~ "MaxListeners"

    assert_raise ArgumentError, ~r/The value of "n" is out of range/, fn ->
      EventEmitter.set_max_listeners(emitter, -1)
    end
  end
end
