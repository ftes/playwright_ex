defmodule Playwright.Helpers.TaskCompletionSource do
  @moduledoc """
  Elixir stand-in for `System.Threading.Tasks.TaskCompletionSource<T>` held as a field of a
  ChannelOwner (`_closedTcs`, `_closeTcs`, `ClosedOrCrashedTcs`). The result is an ETS field of the
  owner; completion is broadcast as an event so `await/1` (C# `await tcs.Task`) can block in any
  process.
  """
  alias Playwright.Transport.ChannelOwner

  defstruct [:owner, :name]

  def new(owner, name), do: %__MODULE__{owner: owner, name: name}

  def try_set_result(%__MODULE__{owner: owner, name: name}, value) do
    if ChannelOwner.get(owner, {:tcs, name}) == nil do
      ChannelOwner.set(owner, {:tcs, name}, {:ok, value})
      ChannelOwner.emit(owner, {:tcs, name}, value)
      true
    else
      false
    end
  end

  def await(%__MODULE__{owner: owner, name: name}) do
    ref = ChannelOwner.subscribe(owner, {:tcs, name})

    try do
      case ChannelOwner.get(owner, {:tcs, name}) do
        {:ok, value} -> value
        nil -> receive(do: ({:playwright_event, ^ref, value} -> value))
      end
    after
      ChannelOwner.unsubscribe(owner, {:tcs, name}, ref)
    end
  end
end
