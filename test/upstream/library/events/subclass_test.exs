# (outside the test module: parity reads nested modules as specs)
# class MyEE extends EventEmitter
defmodule PlaywrightEx.Library.Events.SubclassTest.MyEE do
  @moduledoc false
  defstruct [:guid, :loop, :heap]
  use PlaywrightEx.Client.EventEmitter

  def new(cb) do
    this = PlaywrightEx.Runtime.Heap.new_object(__MODULE__)
    once(this, 1, cb)
    emit(this, 1)
    remove_all_listeners(this)
    this
  end
end

# class MyEE2 { ee: EventEmitter }
defmodule PlaywrightEx.Library.Events.SubclassTest.MyEE2 do
  @moduledoc false
  defstruct [:ee]
  def new, do: %__MODULE__{ee: PlaywrightEx.Client.EventEmitter.new()}
end

defmodule PlaywrightEx.Library.Events.SubclassTest do
  @upstream "tests/library/events/subclass.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Library.Events.SubclassTest.MyEE
  alias PlaywrightEx.Library.Events.SubclassTest.MyEE2
  alias PlaywrightEx.Runtime.EventLoop

  # The emitters live in a heap of their own loop (no driver needed).
  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  test "myee instance", %{loop: loop} do
    myee = EventLoop.with_baton(loop, fn -> MyEE.new(fn _ -> nil end) end)
    # expect(myee._events).not.toBeInstanceOf(Object)  -- JS-only: `_events` is Object.create(null)
    assert MyEE.event_names(myee) == []
  end

  test "MyEE2 instance", %{loop: loop} do
    ee1 = EventLoop.with_baton(loop, &MyEE2.new/0)
    ee2 = EventLoop.with_baton(loop, &MyEE2.new/0)

    EventEmitter.on(ee1.ee, "x", fn _ -> nil end)
    assert EventEmitter.listener_count(ee2.ee, "x") == 0
  end
end
