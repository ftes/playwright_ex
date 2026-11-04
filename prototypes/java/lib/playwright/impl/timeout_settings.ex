defmodule Playwright.Impl.TimeoutSettings do
  # upstream: TimeoutSettings.java:19
  alias Playwright.Impl.{Heap, WaitableNever, WaitableTimeout}

  @default_timeout_ms 30_000
  @default_launch_timeout_ms 180_000

  defstruct [:id, :parent]

  # upstream: TimeoutSettings.java:27
  def new(parent \\ nil), do: %__MODULE__{id: make_ref(), parent: parent}

  # upstream: TimeoutSettings.java:34
  def default_timeout(this), do: Heap.get(this, :default_timeout)

  # upstream: TimeoutSettings.java:37
  def default_navigation_timeout(this), do: Heap.get(this, :default_navigation_timeout)

  # upstream: TimeoutSettings.java:41
  def set_default_timeout(this, timeout), do: Heap.put(this, :default_timeout, timeout)

  # upstream: TimeoutSettings.java:45
  def set_default_navigation_timeout(this, timeout), do: Heap.put(this, :default_navigation_timeout, timeout)

  # upstream: TimeoutSettings.java:49
  def timeout(this, timeout) do
    cond do
      timeout != nil -> timeout
      default_timeout(this) != nil -> default_timeout(this)
      this.parent != nil -> timeout(this.parent, timeout)
      true -> @default_timeout_ms
    end
  end

  # upstream: TimeoutSettings.java:62
  def navigation_timeout(this, timeout) do
    cond do
      timeout != nil -> timeout
      default_navigation_timeout(this) != nil -> default_navigation_timeout(this)
      default_timeout(this) != nil -> default_timeout(this)
      this.parent != nil -> navigation_timeout(this.parent, timeout)
      true -> @default_timeout_ms
    end
  end

  # upstream: TimeoutSettings.java:78
  def create_waitable(this, timeout) do
    if timeout != nil and timeout == 0 do
      %WaitableNever{}
    else
      WaitableTimeout.new(timeout(this, timeout))
    end
  end

  # upstream: TimeoutSettings.java:85
  def launch_timeout(timeout) do
    if timeout != nil, do: timeout, else: @default_launch_timeout_ms
  end
end
