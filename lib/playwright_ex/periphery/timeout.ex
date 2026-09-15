defmodule PlaywrightEx.Timeout do
  @moduledoc false

  def deadline(:infinity), do: :infinity
  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  def remaining(:infinity), do: :infinity
  def remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  def add(:infinity, _delay), do: :infinity
  def add(0, _delay), do: 0
  def add(timeout, delay), do: timeout + delay
end
