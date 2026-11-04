# upstream: packages/playwright-core/src/client/channelOwner.ts
#
# `abstract class ChannelOwner extends EventEmitter` -> `use PlaywrightJS.Client.ChannelOwner`
# injects the struct (`guid` + loop handle) and the inherited methods; `super(...)` in a
# subclass constructor is `ChannelOwner.new(__MODULE__, parent, type, guid, initializer)`.
# `this._channel.foo(params, options)` (Proxy get-trap) is `channel_call(this, :foo, params, options)`.
defmodule PlaywrightJS.Client.ChannelOwner do
  import PlaywrightJS.Runtime.Heap
  alias PlaywrightJS.Runtime.{Promise, Zones}
  alias PlaywrightJS.Client.{ClientStackTrace, Connection, EventEmitter, TimeoutSettings}
  require Logger

  use PlaywrightJS.Client.Api, api_name: false

  defmacro __using__(_opts) do
    quote do
      use PlaywrightJS.Client.Api
      import PlaywrightJS.Runtime.Heap
      import PlaywrightJS.Client.ChannelOwner, only: [channel_call: 3, channel_call: 4, _channel: 1]
      alias PlaywrightJS.Client.{ChannelOwner, EventEmitter, Events, TimeoutSettings}
      alias PlaywrightJS.Runtime.Promise

      defstruct [:guid, :conn]

      use PlaywrightJS.Client.EventEmitter
      defdelegate on(this, event, listener), to: PlaywrightJS.Client.ChannelOwner
      defdelegate add_listener(this, event, listener), to: PlaywrightJS.Client.ChannelOwner
      defdelegate prepend_listener(this, event, listener), to: PlaywrightJS.Client.ChannelOwner
      defdelegate off(this, event, listener), to: PlaywrightJS.Client.ChannelOwner
      defdelegate remove_listener(this, event, listener), to: PlaywrightJS.Client.ChannelOwner
      defdelegate _wrap_api_call(this, func, options \\ %{}), to: PlaywrightJS.Client.ChannelOwner
      defdelegate _parent_of_type(this, type), to: PlaywrightJS.Client.ChannelOwner
      defdelegate _set_event_to_subscription_mapping(this, mapping), to: PlaywrightJS.Client.ChannelOwner
      def __channel_owner__, do: true
    end
  end

  def is_channel_owner(%module{}), do: function_exported?(module, :__channel_owner__, 0)
  def is_channel_owner(_), do: false

  # upstream: channelOwner.ts:48
  def new(module, parent, type, guid, initializer) do
    connection = if is_channel_owner(parent), do: get(parent, :_connection), else: parent
    this = struct(module, guid: guid, conn: connection.conn)
    # super(); this.setMaxListeners(0);  -- EventEmitter state is implicit
    put(this, :_connection, connection)
    put(this, :_type, type)
    put(this, :_guid, guid)
    put(this, :_parent, if(is_channel_owner(parent), do: parent))
    # this._instrumentation = this._connection._instrumentation;  -- not ported: instrumentation

    map_set(connection, :_objects, guid, this)

    if get(this, :_parent) do
      map_set(get(this, :_parent), :_objects, guid, this)
      put(this, :_logger, get(get(this, :_parent), :_logger))
    end

    # this._channel = this._createChannel(new EventEmitter());  -- see _channel/1
    put(this, :_initializer, initializer)
    this
  end

  # The separate EventEmitter behind `this._channel` (protocol events).
  def _channel(this), do: %EventEmitter{guid: {:channel, this.guid}, conn: this.conn}

  # upstream: channelOwner.ts:68
  def _set_event_to_subscription_mapping(this, mapping) do
    put(this, :_eventToSubscriptionMapping, mapping)
  end

  # upstream: channelOwner.ts:72
  defp _update_subscription(this, event, enabled) do
    protocol_event = (get(this, :_eventToSubscriptionMapping) || %{})[event]

    if protocol_event,
      do:
        Promise.catch_(
          Promise.async(this.conn, fn ->
            channel_call(this, :updateSubscription, %{event: protocol_event, enabled: enabled}, TimeoutSettings.k_no_timeout())
          end),
          fn _ -> nil end
        )
  end

  # upstream: channelOwner.ts:78
  def on(this, event, listener) do
    if listener_count(this, event) == 0, do: _update_subscription(this, event, true)
    EventEmitter.on(this, event, listener)
    this
  end

  # upstream: channelOwner.ts:85
  def add_listener(this, event, listener) do
    if listener_count(this, event) == 0, do: _update_subscription(this, event, true)
    EventEmitter.add_listener(this, event, listener)
    this
  end

  # upstream: channelOwner.ts:92
  def prepend_listener(this, event, listener) do
    if listener_count(this, event) == 0, do: _update_subscription(this, event, true)
    EventEmitter.prepend_listener(this, event, listener)
    this
  end

  # upstream: channelOwner.ts:99
  def off(this, event, listener) do
    EventEmitter.off(this, event, listener)
    if listener_count(this, event) == 0, do: _update_subscription(this, event, false)
    this
  end

  # upstream: channelOwner.ts:106
  def remove_listener(this, event, listener) do
    EventEmitter.remove_listener(this, event, listener)
    if listener_count(this, event) == 0, do: _update_subscription(this, event, false)
    this
  end

  defp listener_count(this, event), do: EventEmitter.listener_count(this, event)

  # upstream: channelOwner.ts:113
  def _adopt(this, child) do
    map_delete(get(child, :_parent), :_objects, child.guid)
    map_set(this, :_objects, child.guid, child)
    put(child, :_parent, this)
  end

  # upstream: channelOwner.ts:119
  def _parent_of_type(this, type) do
    parent = get(this, :_parent)

    cond do
      parent == nil -> nil
      get(parent, :_type) == type -> parent
      true -> _parent_of_type(parent, type)
    end
  end

  # upstream: channelOwner.ts:129
  def _dispose(this, reason) do
    # Clean up from parent and connection.
    if get(this, :_parent), do: map_delete(get(this, :_parent), :_objects, this.guid)
    map_delete(get(this, :_connection), :_objects, this.guid)
    put(this, :_wasCollected, reason == "gc")

    # Dispose all children.
    for object <- map_values(this, :_objects), do: _dispose(object, reason)
    map_clear(this, :_objects)
  end

  # upstream: channelOwner.ts:157 (_createChannel: the Proxy `get` trap)
  def channel_call(this, method, params, options \\ %{}) do
    # const validator = maybeFindValidator(this._type, prop, 'Params');  -- not ported: codegen (transport converts channels)
    %{internal: internal} = PlaywrightJS.Protocol.Metainfo.get(get(this, :_type), method)

    _wrap_api_call(
      this,
      fn api_zone ->
        validated_params = params
        %{signal: signal, timeout: timeout} = Map.merge(%{signal: nil, timeout: 0}, options)

        if !api_zone.internal and !api_zone.reported do
          # Reporting/tracing/logging this api call for the first time.
          api_zone = Zones.update(:apiZone, &%{&1 | reported: true}) || api_zone
          # this._instrumentation.onApiCallBegin(apiZone, { type: this._type, method: prop, params });  -- not ported
          log_api_call(get(this, :_logger), "=> #{api_zone.apiName} started")

          Connection.send_message_to_server(
            get(this, :_connection),
            this,
            to_string(method),
            validated_params,
            Map.merge(api_zone, %{signal: signal, timeout: timeout})
          )
        else
          # Since this api call is either internal, or has already been reported/traced once,
          # passing as internal.
          Connection.send_message_to_server(get(this, :_connection), this, to_string(method), validated_params, %{
            internal: true,
            signal: signal,
            timeout: timeout
          })
        end
      end,
      %{internal: internal}
    )
  end

  # upstream: channelOwner.ts:189
  def _wrap_api_call(this, func, options \\ %{}) do
    logger = get(this, :_logger)
    existing_api_zone = Zones.data(:apiZone)

    if existing_api_zone do
      func.(existing_api_zone)
    else
      stack_trace = ClientStackTrace.capture_library_stack_trace()
      api_name = stack_trace.apiName
      api_name = if String.starts_with?(api_name, "_") or String.contains?(api_name, "._"), do: options[:title] || api_name, else: api_name

      api_zone = %{
        title: options[:title],
        apiName: api_name,
        frames: stack_trace.frames,
        internal: options[:internal] || false,
        reported: false,
        userData: nil,
        callId: nil
      }

      try do
        result = Zones.with(:apiZone, api_zone, fn -> func.(api_zone) end)

        if !options[:internal] do
          log_api_call(logger, "<= #{api_zone.apiName} succeeded")
          # this._instrumentation.onApiCallEnd(apiZone);  -- not ported
        end

        result
      rescue
        e ->
          # const innerError = ...  -- not ported: stack rewriting (Elixir keeps __STACKTRACE__)
          e =
            if api_zone.apiName != "" and !String.contains?(api_zone.apiName, "<anonymous>") and Map.has_key?(e, :message),
              do: Map.put(e, :message, api_zone.apiName <> ": " <> Exception.message(e)),
              else: e

          # const stackFrames = ...; e.stack = ...  -- not ported: stack rewriting

          if !options[:internal] do
            log_api_call(logger, "<= #{api_zone.apiName} failed")
            # this._instrumentation.onApiCallEnd(apiZone);  -- not ported
          end

          reraise e, __STACKTRACE__
      end
    end
  end

  # upstream: channelOwner.ts:238
  defp log_api_call(_logger, message) do
    # if (logger && logger.isEnabled('api', 'info')) logger.log(...)  -- not ported: user Logger
    Logger.debug("pw:api " <> message)
  end
end
