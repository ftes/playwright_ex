defmodule Playwright.Impl.WaitableEvent do
  # upstream: WaitableEvent.java:22
  # `class WaitableEvent implements Waitable, Consumer`. Subclasses (`extends WaitableEvent`) `use` this module and
  # override get/1. `outer` holds the enclosing instance for Java inner classes (e.g. PageImpl.WaitablePageClose).
  # The mutable `eventArg` field lives in the Heap so that accept/2 may run in any process.
  alias Playwright.Impl.{Heap, ListenerCollection, Waitable}

  @behaviour Waitable
  defstruct [:id, :listeners, :type, :predicate, :outer]

  defmacro __using__(_) do
    quote do
      @behaviour Playwright.Impl.Waitable
      defstruct [:id, :listeners, :type, :predicate, :outer]
      defdelegate is_done(this), to: Playwright.Impl.WaitableEvent
      defdelegate dispose(this), to: Playwright.Impl.WaitableEvent
      defdelegate get(this), to: Playwright.Impl.WaitableEvent
      defoverridable is_done: 1, dispose: 1, get: 1
    end
  end

  # upstream: WaitableEvent.java:28
  def new(listeners, type, predicate \\ nil), do: init(__MODULE__, listeners, type, predicate, nil)

  # upstream: WaitableEvent.java:32
  def init(module, listeners, type, predicate, outer) do
    this = struct!(module, id: make_ref(), listeners: listeners, type: type, predicate: predicate, outer: outer)
    ListenerCollection.add(listeners, type, consumer(this))
    this
  end

  # Java passes `this` as the Consumer; closures with equal environments compare equal, so this is stable.
  defp consumer(this), do: fn event_arg -> accept(this, event_arg) end

  # upstream: WaitableEvent.java:40
  def accept(this, event_arg) do
    if this.predicate != nil and !this.predicate.(event_arg) do
      nil
    else
      Heap.put(this, :event_arg, event_arg)
      Waitable.dispose(this)
    end
  end

  # upstream: WaitableEvent.java:50
  def is_done(this), do: Heap.get(this, :event_arg) != nil

  # upstream: WaitableEvent.java:55
  def dispose(this), do: ListenerCollection.remove(this.listeners, this.type, consumer(this))

  # upstream: WaitableEvent.java:60
  def get(this), do: Heap.get(this, :event_arg)
end
