defmodule Playwright.Impl.WaitableTimeout do
  # upstream: WaitableTimeout.java:21
  alias Playwright.TimeoutError

  @behaviour Playwright.Impl.Waitable
  defstruct [:deadline, :timeout]

  # upstream: WaitableTimeout.java:25
  def new(millis) do
    %__MODULE__{timeout: millis, deadline: System.monotonic_time(:nanosecond) + trunc(millis) * 1_000_000}
  end

  # upstream: WaitableTimeout.java:31
  @impl true
  def is_done(this), do: System.monotonic_time(:nanosecond) > this.deadline

  # upstream: WaitableTimeout.java:36
  @impl true
  def get(this) do
    timeout_str = to_string(this.timeout)
    timeout_str = String.replace_suffix(timeout_str, ".0", "")
    raise TimeoutError, message: "Timeout " <> timeout_str <> "ms exceeded"
  end

  # upstream: WaitableTimeout.java:45
  @impl true
  def dispose(_this), do: nil
end
