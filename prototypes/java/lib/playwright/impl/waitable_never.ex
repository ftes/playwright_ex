defmodule Playwright.Impl.WaitableNever do
  # upstream: WaitableNever.java:19
  @behaviour Playwright.Impl.Waitable
  defstruct []

  # upstream: WaitableNever.java:21
  @impl true
  def is_done(_this), do: false

  # upstream: WaitableNever.java:26
  @impl true
  def get(_this), do: raise("Should never be called")

  # upstream: WaitableNever.java:31
  @impl true
  def dispose(_this), do: nil
end
