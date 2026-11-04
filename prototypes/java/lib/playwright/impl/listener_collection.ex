defmodule Playwright.Impl.ListenerCollection do
  # upstream: ListenerCollection.java:25
  # Listeners are `{owner_pid, consumer_fun}`. Java invokes listeners on the thread that pumps messages; here
  # notify/3 runs in the Connection process and forwards each call to the process that registered the
  # listener, which runs it the next time it pumps (Connection.process_one_message/1). This keeps Java's
  # "listeners only fire while the owner thread is inside a Playwright call" semantics.
  alias Playwright.Impl.{ChannelOwner, Heap}
  alias Playwright.PlaywrightException

  defstruct [:id, :event_subscriptions, :channel_owner]

  # upstream: ListenerCollection.java:33
  def new(event_subscriptions \\ nil, channel_owner \\ nil) do
    %__MODULE__{id: make_ref(), event_subscriptions: event_subscriptions, channel_owner: channel_owner}
  end

  # upstream: ListenerCollection.java:38
  def notify(this, event_type, param) do
    list = Heap.get(this, event_type)

    if list != nil do
      for {owner, listener} <- list, do: run_in_owner(owner, fn -> listener.(param) end)
    end
  end

  # upstream: ListenerCollection.java:49
  def add(this, type, listener) do
    if listener == nil, do: raise(PlaywrightException, message: "Can't add a null listener")
    list = Heap.get(this, type)

    list =
      if list == nil do
        update_subscription(this, type, true)
        []
      else
        list
      end

    Heap.put(this, type, list ++ [{self(), listener}])
  end

  # upstream: ListenerCollection.java:62
  def remove(this, type, listener) do
    list = Heap.get(this, type)

    if list != nil do
      list = Enum.reject(list, fn {_owner, l} -> l == listener end)
      Heap.put(this, type, list)

      if list == [] do
        update_subscription(this, type, false)
        Heap.put(this, type, nil)
      end
    end
  end

  # upstream: ListenerCollection.java:74
  def has_listeners(this, type), do: Heap.get(this, type) != nil

  # upstream: ListenerCollection.java:78
  defp update_subscription(this, event_type, enabled) do
    protocol_event = this.event_subscriptions && this.event_subscriptions[event_type]

    if protocol_event != nil do
      params = %{"event" => protocol_event, "enabled" => enabled}
      ChannelOwner.send_message_async(this.channel_owner, "updateSubscription", params)
    end
  end

  # No upstream counterpart: OTP replacement for "call the listener on the owner thread".
  def run_in_owner(owner, fun) do
    if owner == self(), do: fun.(), else: send(owner, {:playwright_run, fun})
  end
end
