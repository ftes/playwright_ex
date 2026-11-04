defmodule Playwright.Core.TimeoutSettings do
  @moduledoc """
  upstream: Core/TimeoutSettings.cs

  A mutable non-ChannelOwner object; its fields are stored on the ChannelOwner that holds it
  (`owner`), `nil` owner = a fresh `new TimeoutSettings()` with all defaults.
  """
  alias Playwright.Transport.ChannelOwner

  defstruct [:owner, :parent]

  @default_timeout_in_milliseconds 30_000
  @default_launch_timeout_in_milliseconds 180_000

  # upstream: Core/TimeoutSettings.cs:36
  def new(owner \\ nil, parent \\ nil), do: %__MODULE__{owner: owner, parent: parent}

  # upstream: Core/TimeoutSettings.cs:41
  def default_navigation_timeout(this), do: field(this, :default_navigation_timeout)

  # upstream: Core/TimeoutSettings.cs:43
  def default_timeout(this), do: field(this, :default_timeout)

  # upstream: Core/TimeoutSettings.cs:45
  def launch_timeout(timeout) do
    if timeout != nil do
      timeout
    else
      @default_launch_timeout_in_milliseconds
    end
  end

  # upstream: Core/TimeoutSettings.cs:55
  def set_default_timeout(this, timeout), do: ChannelOwner.set(this.owner, {__MODULE__, :default_timeout}, timeout)

  # upstream: Core/TimeoutSettings.cs:60
  def set_default_navigation_timeout(this, timeout),
    do: ChannelOwner.set(this.owner, {__MODULE__, :default_navigation_timeout}, timeout)

  # upstream: Core/TimeoutSettings.cs:65
  def navigation_timeout(this, timeout) do
    cond do
      timeout != nil -> timeout
      default_navigation_timeout(this) != nil -> default_navigation_timeout(this)
      default_timeout(this) != nil -> default_timeout(this)
      this.parent != nil -> navigation_timeout(this.parent, timeout)
      true -> @default_timeout_in_milliseconds
    end
  end

  # upstream: Core/TimeoutSettings.cs:90
  def timeout(this, timeout) do
    cond do
      timeout != nil -> timeout
      default_timeout(this) != nil -> default_timeout(this)
      this.parent != nil -> timeout(this.parent, timeout)
      true -> @default_timeout_in_milliseconds
    end
  end

  defp field(%{owner: nil}, _), do: nil
  defp field(this, name), do: ChannelOwner.get(this.owner, {__MODULE__, name})
end
