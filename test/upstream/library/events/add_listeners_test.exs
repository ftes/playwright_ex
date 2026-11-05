defmodule PlaywrightEx.Library.Events.AddListenersTest do
  @upstream "tests/library/events/add-listeners.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap

  # The emitters live in a heap of their own loop (no driver needed).
  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  defp new_ee(loop), do: EventLoop.with_baton(loop, fn -> Heap.new_object(EventEmitter) end)

  def listen1(_), do: nil
  def listen2(_), do: nil

  # Listeners run in handed-off processes: what they see is sent to the test process.
  defp received(tag) do
    receive do
      {^tag, value} -> [value | received(tag)]
    after
      0 -> []
    end
  end

  describe "EventEmitter tests" do
    # `newListener` listeners get `{event, listener}` (one event argument, see EventEmitter).
    test "should work", %{loop: loop} do
      test = self()
      ee = new_ee(loop)

      EventEmitter.on(ee, "newListener", fn {event, listener} ->
        if event != "newListener", do: send(test, {:new_listener_emitted, {event, listener}})
      end)

      hello = fn [a, b] -> send(test, {:hello, {a, b}}) end

      EventEmitter.once(ee, "newListener", fn {name, listener} ->
        send(test, {:once_new_listener, {name, listener, EventEmitter.listeners(ee, "hello")}})
      end)

      EventEmitter.on(ee, "hello", hello)
      EventEmitter.once(ee, "foo", fn _ -> raise "foo error" end)

      assert [{"hello", hello_listener}, {"foo", foo_listener}] = received(:new_listener_emitted)
      assert hello_listener == hello
      assert_raise RuntimeError, "foo error", fn -> foo_listener.(nil) end
      assert received(:once_new_listener) == [{"hello", hello, []}]

      EventEmitter.emit(ee, "hello", ["a", "b"])
      assert received(:hello) == [{"a", "b"}]
    end

    test "set max listeners test", %{loop: loop} do
      f = new_ee(loop)
      EventEmitter.set_max_listeners(f, 0)
    end

    test "Listener order", %{loop: loop} do
      test = self()
      ee = new_ee(loop)

      EventEmitter.once(ee, "newListener", fn _ ->
        send(test, {:listeners, EventEmitter.listeners(ee, "hello")})

        EventEmitter.once(ee, "newListener", fn _ ->
          send(test, {:listeners, EventEmitter.listeners(ee, "hello")})
        end)

        EventEmitter.on(ee, "hello", &listen2/1)
      end)

      EventEmitter.on(ee, "hello", &listen1/1)
      listeners = EventEmitter.listeners(ee, "hello")
      assert is_list(listeners)
      assert length(listeners) == 2
      assert Enum.at(listeners, 0) == (&listen2/1)
      assert Enum.at(listeners, 1) == (&listen1/1)
      assert received(:listeners) == [[], []]
    end

    # JS `null` is `:null`; TypeError is ArgumentError.
    test "listener type check", %{loop: loop} do
      ee = new_ee(loop)

      assert_raise ArgumentError, ~s(The "listener" argument must be of type Function. Received type object), fn ->
        EventEmitter.on(ee, "foo", :null)
      end
    end
  end
end
