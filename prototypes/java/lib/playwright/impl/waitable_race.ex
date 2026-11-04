defmodule Playwright.Impl.WaitableRace do
  # upstream: WaitableRace.java:21
  alias Playwright.Impl.{Heap, Waitable}

  @behaviour Waitable
  defstruct [:id, :waitables]

  # upstream: WaitableRace.java:25
  def new(waitables), do: %__MODULE__{id: make_ref(), waitables: waitables}

  # upstream: WaitableRace.java:30
  @impl true
  def is_done(this) do
    if Heap.get(this, :first_ready) != nil do
      true
    else
      case Enum.find(this.waitables, &Waitable.is_done/1) do
        nil -> false
        w -> Heap.put(this, :first_ready, w) && true
      end
    end
  end

  # upstream: WaitableRace.java:44
  @impl true
  def get(this) do
    try do
      Waitable.get(Heap.get(this, :first_ready))
    after
      dispose(this)
    end
  end

  # upstream: WaitableRace.java:53
  @impl true
  def dispose(this) do
    for w <- this.waitables, do: Waitable.dispose(w)
  end
end
