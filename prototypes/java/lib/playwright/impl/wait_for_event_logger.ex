defmodule Playwright.Impl.WaitForEventLogger do
  # upstream: WaitForEventLogger.java:26  (implements Supplier<T>, Logger)
  alias Playwright.Impl.{ChannelOwner, LoggingSupport, Utils}

  defstruct [:supplier, :channel, :wait_id, :api_name]

  # upstream: WaitForEventLogger.java:32
  def new(channel_owner, api_name, supplier) do
    %__MODULE__{supplier: supplier, channel: channel_owner, api_name: api_name, wait_id: Utils.create_guid()}
  end

  # upstream: WaitForEventLogger.java:40
  def get(this) do
    send_wait_info(this, %{"phase" => "before", "event" => ""})
    info = %{"phase" => "after"}

    try do
      this.supplier.(this)
    rescue
      e ->
        send_wait_info(this, Map.put(info, "error", Exception.message(e)))
        reraise e, __STACKTRACE__
    else
      result ->
        send_wait_info(this, info)
        result
    end
  end

  # upstream: WaitForEventLogger.java:60
  def log(this, message) do
    LoggingSupport.log_api_if_enabled(message)
    send_wait_info(this, %{"phase" => "log", "message" => message})
  end

  # upstream: WaitForEventLogger.java:68
  defp send_wait_info(this, info) do
    info = Map.put(info, "waitId", this.wait_id)

    try do
      ChannelOwner.send_message_no_reply(this.channel, "__waitInfo__", info)
    rescue
      # Fire-and-forget: never throw to the caller.
      _ -> nil
    end
  end
end
