defmodule Playwright.Impl.WaitableResult do
  # upstream: WaitableResult.java:22
  # Completed by the Connection process (dispatch) and awaited by the client process that created it, so the
  # mutable fields live in the Heap and completion wakes the owner's message pump.
  alias Playwright.Impl.{Heap, ListenerCollection}

  @behaviour Playwright.Impl.Waitable
  defstruct [:id, :owner]

  def new, do: %__MODULE__{id: make_ref(), owner: self()}

  # upstream: WaitableResult.java:27
  def complete(this, result) do
    if is_done(this) do
      nil
    else
      Heap.put(this, :result, result)
      Heap.put(this, :is_done, true)
      ListenerCollection.run_in_owner(this.owner, fn -> nil end)
    end
  end

  # upstream: WaitableResult.java:35
  def complete_exceptionally(this, exception) do
    if is_done(this) do
      nil
    else
      Heap.put(this, :exception, exception)
      Heap.put(this, :is_done, true)
      ListenerCollection.run_in_owner(this.owner, fn -> nil end)
    end
  end

  # upstream: WaitableResult.java:44
  @impl true
  def is_done(this), do: Heap.get(this, :is_done, false)

  # upstream: WaitableResult.java:49
  # Java re-creates the exception (same class) to get the calling thread's stack trace; `raise` does that here.
  @impl true
  def get(this) do
    exception = Heap.get(this, :exception)
    if exception != nil, do: raise(exception)
    Heap.get(this, :result)
  end

  # upstream: WaitableResult.java:64
  @impl true
  def dispose(this), do: Heap.delete_all(this)
end
