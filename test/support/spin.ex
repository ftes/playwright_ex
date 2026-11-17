defmodule Playwright.Spin do
  @moduledoc false
  # Synchronous work for tests that hold a synchronous section open (a listener's, an async
  # function's): a `receive` or `Process.sleep/1` there is released as an await after about 30 ms
  # (`Playwright.Runtime.Invocation.judge/3`), busy work is not, as in JS.

  import ExUnit.Assertions

  @doc "Spins for `ms` ms (an integer), or until `done?` returns true; fails after 10 s."
  def until(ms) when is_integer(ms) do
    deadline = now() + ms
    until(fn -> now() >= deadline end)
  end

  def until(done?) when is_function(done?, 0), do: until(done?, now() + 10_000)

  @doc "Spins until the `:atomics` cell `ref` (1 cell) is set to 1 (`release/1`)."
  def hold(ref), do: until(fn -> :atomics.get(ref, 1) == 1 end)

  @doc "A cell for `hold/1`."
  def new, do: :atomics.new(1, [])

  @doc "Ends `hold/1` on `ref`."
  def release(ref), do: :atomics.put(ref, 1, 1)

  defp until(done?, deadline) do
    cond do
      done?.() -> :ok
      now() > deadline -> flunk("Playwright.Spin: still spinning after 10 s")
      true -> until(done?, deadline)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
