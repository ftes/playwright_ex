# upstream: packages/playwright-core/src/client/connection.ts
defmodule PlaywrightJS.Client.Connection do
  import PlaywrightJS.Runtime.Heap
  alias PlaywrightJS.Runtime.{Loop, Promise}

  alias PlaywrightJS.Client.{
    Artifact,
    Browser,
    BrowserContext,
    BrowserType,
    ChannelOwner,
    Errors,
    EventEmitter,
    Frame,
    Network,
    Page,
    Playwright,
    TimeoutSettings
  }

  use EventEmitter
  defstruct [:guid, :conn]

  # upstream: connection.ts:57
  defmodule Root do
    use ChannelOwner

    # upstream: connection.ts:58
    def new(connection) do
      ChannelOwner.new(__MODULE__, connection, "Root", "", %{})
    end

    # upstream: connection.ts:62
    def initialize(this) do
      PlaywrightJS.Client.Playwright.from(
        channel_call(this, :initialize, %{sdkLanguage: "javascript"}, TimeoutSettings.k_no_timeout()).playwright
      )
    end
  end

  # upstream: connection.ts:69 (also stands in for every class that is not ported)
  defmodule DummyChannelOwner do
    use ChannelOwner
    def new(parent, type, guid, initializer), do: ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    def from(channel), do: channel
  end

  # upstream: connection.ts:92
  def new(%Loop{} = loop, local_utils \\ nil, _instrumentation \\ nil, headers \\ []) do
    Loop.exec(loop, fn ->
      this = %__MODULE__{guid: :connection, conn: loop}
      # super();
      put(this, :onmessage, fn _message -> nil end)
      put(this, :_nextCallId, create_call_id_generator())
      put(this, :_isRemote, false)
      put(this, :_rawBuffers, false)
      put(this, :_tracingCount, 0)
      # this._instrumentation = instrumentation || createInstrumentation();  -- not ported
      put(this, :_localUtils, local_utils)
      put(this, :_rootObject, Root.new(this))
      put(this, :headers, headers)
      dummy = &DummyChannelOwner.new/4

      register_object_factories(this, %{
        "Android" => dummy,
        "AndroidDevice" => dummy,
        "AndroidSocket" => dummy,
        "APIRequestContext" => dummy,
        "Artifact" => &Artifact.new/4,
        "BindingCall" => dummy,
        "Browser" => &Browser.new/4,
        "BrowserContext" => &BrowserContext.new/4,
        "BrowserType" => &BrowserType.new/4,
        "CDPSession" => dummy,
        "Debugger" => dummy,
        "Dialog" => dummy,
        "Disposable" => dummy,
        "Electron" => dummy,
        "ElectronApplication" => dummy,
        "ElementHandle" => dummy,
        "Frame" => &Frame.new/4,
        "JSHandle" => dummy,
        "JsonPipe" => dummy,
        "LocalUtils" => fn parent, type, guid, init ->
          result = DummyChannelOwner.new(parent, type, guid, init)
          if !get(this, :_localUtils), do: put(this, :_localUtils, result)
          result
        end,
        "Page" => &Page.new/4,
        "Playwright" => &Playwright.new/4,
        "Request" => &Network.Request.new/4,
        "Response" => &Network.Response.new/4,
        "Route" => dummy,
        "Stream" => dummy,
        "SocksSupport" => dummy,
        "Tracing" => dummy,
        "WebSocket" => dummy,
        "WebSocketRoute" => dummy,
        "Worker" => dummy,
        "WritableStream" => dummy
      })

      this
    end)
  end

  # upstream: connection.ts:139
  def register_object_factories(this, factories) do
    for {type, factory} <- factories, do: map_set(this, :_objectFactories, type, factory)
  end

  # upstream: connection.ts:144
  def mark_as_remote(this) do
    put(this, :_isRemote, true)
  end

  # upstream: connection.ts:148
  def is_remote(this) do
    get(this, :_isRemote)
  end

  # upstream: connection.ts:160
  def local_utils(this) do
    get(this, :_localUtils)
  end

  # upstream: connection.ts:164
  def initialize_playwright(this) do
    Root.initialize(get(this, :_rootObject))
  end

  # upstream: connection.ts:168
  def get_object_with_known_name(this, guid) do
    map_get(this, :_objects, guid)
  end

  # upstream: connection.ts:179
  def send_message_to_server(this, object, method, params, options) do
    cond do
      # Fire-and-forget: server intentionally never replies to __waitInfo__,
      # so silently drop it after the connection is closed or the object was collected.
      method == "__waitInfo__" and (get(this, :_closedError) || get(object, :_wasCollected)) ->
        nil

      get(this, :_closedError) ->
        raise get(this, :_closedError)

      get(object, :_wasCollected) ->
        raise "The object has been collected to prevent unbounded heap growth."

      true ->
        # const signal = options.signal; if (signal?.aborted) ...  -- not ported: AbortSignal
        guid = object.guid
        type = get(object, :_type)
        id = options[:callId] || get(this, :_nextCallId).()
        message = %{id: id, guid: guid, method: method, params: params}
        # debugLogger.log('channel', 'SEND> ' + JSON.stringify(message))  -- not ported
        location = if frame = List.first(options[:frames] || []), do: %{file: frame.file, line: frame.line, column: frame.column}
        metadata = %{title: options[:title], location: location, internal: options[:internal], timeout: options[:timeout]}
        # if (this._tracingCount && ...) addStackToTracingNoReply  -- not ported
        # DEVIATION: the callback is registered before the message is sent; in JS both happen
        # in the same synchronous turn, here the reply could otherwise race the registration.
        promise =
          if method != "__waitInfo__",
            do:
              Promise.new(this.conn, fn resolve, reject ->
                map_set(this, :_callbacks, id, %{resolve: resolve, reject: reject, title: options[:title], type: type, method: method})
              end)

        get(this, :onmessage).(Map.put(message, :metadata, metadata))
        # Fire-and-forget: server intentionally never replies to __waitInfo__.
        if method == "__waitInfo__", do: nil, else: Promise.await(promise)
    end
  end

  # upstream: connection.ts:227 (_validatorFromWireContext + generated validators)
  # Replace `{guid}` channel references with the client objects (tChannelImplFromWire).
  defp _from_wire(this, %{guid: guid} = arg) when map_size(arg) == 1, do: _t_channel_impl_from_wire(this, guid)
  defp _from_wire(this, map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, _from_wire(this, v)} end)
  defp _from_wire(this, list) when is_list(list), do: Enum.map(list, &_from_wire(this, &1))
  defp _from_wire(_this, other), do: other

  # upstream: connection.ts:235
  def dispatch(this, message) do
    %{id: id, guid: guid, method: method, params: params, result: result, error: error, errorDetails: error_details, log: log} =
      Map.merge(%{id: nil, guid: nil, method: nil, params: nil, result: nil, error: nil, errorDetails: nil, log: nil}, message)

    cond do
      get(this, :_closedError) ->
        nil

      id ->
        # debugLogger.log('channel', '<RECV ' + JSON.stringify(message))  -- not ported
        callback = map_get(this, :_callbacks, id)
        if !callback, do: raise("Cannot find command to respond: #{id}")
        map_delete(this, :_callbacks, id)

        if error && !result do
          parsed_error = Errors.parse_error(error)
          # if (callback.signal?.aborted && parsedError instanceof AbortError) ...  -- not ported: AbortSignal
          parsed_error = %{parsed_error | log: log || []}
          parsed_error = Errors.rewrite_error_message(parsed_error, parsed_error.message <> format_call_log(log))
          # const detailsValidator = maybeFindValidator(callback.type, callback.method, 'ErrorDetails');
          parsed_error = %{parsed_error | details: _from_wire(this, error_details || %{})}
          callback.reject.(parsed_error)
        else
          # const validator = findValidator(callback.type, callback.method, 'Result');
          callback.resolve.(_from_wire(this, result || %{}))
        end

      method == "__create__" ->
        # debugLogger.log('channel', '<EVENT ' + JSON.stringify(message))  -- not ported
        _create_remote_object(this, guid, params.type, params.guid, params[:initializer])

      true ->
        object = map_get(this, :_objects, guid)
        if !object, do: raise("Cannot find object to \"#{method}\": #{guid}")

        cond do
          method == "__adopt__" ->
            child = map_get(this, :_objects, params.guid)
            if !child, do: raise("Unknown new child: #{params.guid}")
            ChannelOwner._adopt(object, child)

          method == "__dispose__" ->
            ChannelOwner._dispose(object, params[:reason])

          true ->
            # const validator = findValidator(object._type, method, 'Event');
            EventEmitter.emit(ChannelOwner._channel(object), method, _from_wire(this, params || %{}))
        end
    end
  end

  # upstream: connection.ts:292
  def close(this, cause \\ nil) do
    if !get(this, :_closedError) do
      put(this, :_closedError, Errors.TargetClosedError.new(cause))
      for callback <- map_values(this, :_callbacks), do: callback.reject.(get(this, :_closedError))
      map_clear(this, :_callbacks)
      emit(this, "close")
    end
  end

  # upstream: connection.ts:302
  defp _t_channel_impl_from_wire(this, guid) do
    object = map_get(this, :_objects, guid)
    if !object, do: raise("Object with guid #{guid} was not bound in the connection")
    # if (names !== '*' && !names.includes(object._type)) throw new ValidationError(...)  -- not ported: codegen
    object
  end

  # upstream: connection.ts:314
  defp _create_remote_object(this, parent_guid, type, guid, initializer) do
    parent = map_get(this, :_objects, parent_guid)
    if !parent, do: raise("Cannot find parent object #{parent_guid} to create #{guid}")
    # const validator = findValidator(type, '', 'Initializer');
    initializer = _from_wire(this, initializer || %{})
    factory = map_get(this, :_objectFactories, type)
    if !factory, do: raise("Missing type " <> type)
    factory.(parent, type, guid, initializer)
  end

  # upstream: connection.ts:327
  defp format_call_log(log) do
    if !log or !Enum.any?(log, &(&1 != "")) do
      ""
    else
      "\nCall log:\n#{Enum.join(log, "\n")}\n"
    end
  end

  # upstream: isomorphic/trace/traceUtils.ts:31
  defp create_call_id_generator do
    prefix = for _ <- 1..4, into: "", do: <<Enum.random(?a..?z)>>
    fn -> "#{prefix}@#{System.unique_integer([:positive, :monotonic])}" end
  end
end
