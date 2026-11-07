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

  test "a listener error goes to the error listeners, else it is uncaught (logged)" do
    emitter = EventEmitter.new()
    test_pid = self()
    EventEmitter.on(emitter, "foo", fn _ -> raise "boom" end)
    EventEmitter.on(emitter, "foo", fn arg -> send(test_pid, {:later, arg}) end)

    log = capture_log(fn -> EventEmitter.emit(emitter, "foo", 1) end)
    assert log =~ "Uncaught in event listener" and log =~ "boom"
    assert_received {:later, 1}

    EventEmitter.on(emitter, "error", fn error -> send(test_pid, {:error, error}) end)
    assert capture_log(fn -> EventEmitter.emit(emitter, "foo", 2) end) == ""
    assert_received {:error, %RuntimeError{message: "boom"}}

    # An error listener's own error is not emitted again.
    EventEmitter.on(emitter, "error", fn _ -> raise "error listener" end)
    log = capture_log(fn -> EventEmitter.emit(emitter, "foo", 3) end)
    assert log =~ "error listener"
    assert_received {:error, %RuntimeError{message: "boom"}}
  end

  test "remove_all_listeners with behavior wait: errors of later listeners send no message" do
    emitter = EventEmitter.new()
    assert EventEmitter.remove_all_listeners(emitter, "foo", %{behavior: "wait"}) == nil

    EventEmitter.on(emitter, "foo", fn _ -> raise "after" end)
    EventEmitter.emit(emitter, "foo")
    refute_received _
  end
end
