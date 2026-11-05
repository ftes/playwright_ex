defmodule PlaywrightEx.Client.Connection do
  @upstream "packages/playwright-core/src/client/connection.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  `dispatch/2` takes wire messages as decoded by `PlaywrightEx.Transport.Pipe` (string keys);
  the protocol validators turn results, events and initializers into atom-keyed maps.
  Every connection gets its own heap table (guids are only unique per connection); nested
  connections share the driver's baton.
  """
  use PlaywrightEx.Client.EventEmitter

  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Client.APIRequestContext
  alias PlaywrightEx.Client.Artifact
  alias PlaywrightEx.Client.BindingCall
  alias PlaywrightEx.Client.Browser
  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.BrowserType
  alias PlaywrightEx.Client.CDPSession
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.Debugger
  alias PlaywrightEx.Client.Dialog
  alias PlaywrightEx.Client.DisposableObject
  alias PlaywrightEx.Client.ElementHandle
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.JSHandle
  alias PlaywrightEx.Client.JsonPipe
  alias PlaywrightEx.Client.LocalUtils
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Client.Playwright
  alias PlaywrightEx.Client.Request
  alias PlaywrightEx.Client.Response
  alias PlaywrightEx.Client.Route
  alias PlaywrightEx.Client.Stream
  alias PlaywrightEx.Client.TimeoutSettings
  alias PlaywrightEx.Client.Tracing
  alias PlaywrightEx.Client.WebSocket
  alias PlaywrightEx.Client.WebSocketRoute
  alias PlaywrightEx.Client.Worker
  alias PlaywrightEx.Client.WritableStream
  alias PlaywrightEx.Protocol.Validator
  alias PlaywrightEx.Protocol.ValidatorPrimitives
  alias PlaywrightEx.Protocol.ValidatorPrimitives.ValidationError
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Promise
  alias PlaywrightEx.Runtime.Zones

  defstruct [:guid, :loop, :heap]

  defmodule Root do
    @moduledoc false
    use ChannelOwner

    def new(connection) do
      ChannelOwner.new(__MODULE__, connection, "Root", "", %{})
    end

    def initialize(this) do
      Playwright.from(
        channel_call(this, :initialize, %{sdkLanguage: "javascript"}, TimeoutSettings.k_no_timeout()).playwright
      )
    end
  end

  defmodule DummyChannelOwner do
    @moduledoc false
    use ChannelOwner

    def new(parent, type, guid, initializer), do: ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
  end

  def new(%EventLoop{} = loop, local_utils \\ nil, _instrumentation \\ nil, headers \\ []) do
    heap = EventLoop.new_heap(loop)

    EventLoop.with_baton(loop, fn ->
      this = %__MODULE__{guid: :connection, loop: loop, heap: heap}
      # super();
      put(this, :onmessage, fn _message -> nil end)
      put(this, :_nextCallId, create_call_id_generator())
      put(this, :_isRemote, false)
      put(this, :_rawBuffers, false)
      put(this, :_tracingCount, 0)
      # this._instrumentation = instrumentation || createInstrumentation();  -- not ported: instrumentation
      put(this, :_localUtils, local_utils)
      put(this, :_rootObject, Root.new(this))
      put(this, :headers, headers)
      # Android and Electron are DummyChannelOwners: not ported (android.ts, electron.ts are not in
      # the JS api.json at this pin). SocksSupport is a DummyChannelOwner upstream too.
      dummy = &DummyChannelOwner.new/4

      register_object_factories(this, %{
        "Android" => dummy,
        "AndroidDevice" => dummy,
        "AndroidSocket" => dummy,
        "APIRequestContext" => &APIRequestContext.new/4,
        "Artifact" => &Artifact.new/4,
        "BindingCall" => &BindingCall.new/4,
        "Browser" => &Browser.new/4,
        "BrowserContext" => &BrowserContext.new/4,
        "BrowserType" => &BrowserType.new/4,
        "CDPSession" => &CDPSession.new/4,
        "Debugger" => &Debugger.new/4,
        "Dialog" => &Dialog.new/4,
        "Disposable" => &DisposableObject.new/4,
        "Electron" => dummy,
        "ElectronApplication" => dummy,
        "ElementHandle" => &ElementHandle.new/4,
        "Frame" => &Frame.new/4,
        "JSHandle" => &JSHandle.new/4,
        "JsonPipe" => &JsonPipe.new/4,
        "LocalUtils" => fn parent, type, guid, init ->
          result = LocalUtils.new(parent, type, guid, init)
          if !get(this, :_localUtils), do: put(this, :_localUtils, result)
          result
        end,
        "Page" => &Page.new/4,
        "Playwright" => &Playwright.new/4,
        "Request" => &Request.new/4,
        "Response" => &Response.new/4,
        "Route" => &Route.new/4,
        "Stream" => &Stream.new/4,
        "SocksSupport" => dummy,
        "Tracing" => &Tracing.new/4,
        "WebSocket" => &WebSocket.new/4,
        "WebSocketRoute" => &WebSocketRoute.new/4,
        "Worker" => &Worker.new/4,
        "WritableStream" => &WritableStream.new/4
      })

      this
    end)
  end

  def register_object_factories(this, factories) do
    for {type, factory} <- factories, do: map_set(this, :_objectFactories, type, factory)
  end

  def mark_as_remote(this) do
    put(this, :_isRemote, true)
  end

  def is_remote(this) do
    get(this, :_isRemote)
  end

  def use_raw_buffers(this) do
    put(this, :_rawBuffers, true)
  end

  def raw_buffers(this) do
    get(this, :_rawBuffers)
  end

  def local_utils(this) do
    get(this, :_localUtils)
  end

  def initialize_playwright(this) do
    Root.initialize(get(this, :_rootObject))
  end

  def get_object_with_known_name(this, guid) do
    map_get(this, :_objects, guid)
  end

  def set_is_tracing(this, is_tracing) do
    update(this, :_tracingCount, &if(is_tracing, do: &1 + 1, else: &1 - 1))
  end

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
        location =
          if frame = List.first(options[:frames] || []), do: %{file: frame.file, line: frame.line, column: frame.column}

        metadata = %{
          title: options[:title],
          location: location,
          internal: options[:internal],
          timeout: options[:timeout]
        }

        if get(this, :_tracingCount) > 0 and options[:frames] != nil and type != "LocalUtils" do
          if local_utils = get(this, :_localUtils) do
            Promise.async(fn ->
              LocalUtils.add_stack_to_tracing_no_reply(local_utils, %{
                callData: %{stack: options[:frames] || [], id: id}
              })
            end)
            |> Promise.catch_(fn _ -> nil end)
          end
        end

        # We need to exit zones before calling into the server, otherwise
        # when we receive events from the server, we would be in an API zone.
        Zones.empty(fn -> get(this, :onmessage).(Map.put(message, :metadata, metadata)) end)
        # Fire-and-forget: server intentionally never replies to __waitInfo__.
        if method != "__waitInfo__" do
          # let abortListener ...  -- not ported: AbortSignal
          Promise.await(
            Promise.new(fn resolve, reject ->
              map_set(this, :_callbacks, id, %{
                resolve: resolve,
                reject: reject,
                title: options[:title],
                type: type,
                method: method
              })
            end)
          )
        end
    end
  end

  defp _validator_from_wire_context(this) do
    %{
      tChannelImpl: fn names, arg, path, context -> _t_channel_impl_from_wire(this, names, arg, path, context) end,
      binary: if(get(this, :_rawBuffers), do: "buffer", else: "fromBase64")
    }
  end

  def dispatch(this, message) do
    if !get(this, :_closedError), do: _dispatch(this, message)
  end

  defp _dispatch(this, %{"id" => id} = message) when id != nil do
    %{"result" => result, "error" => error, "errorDetails" => error_details, "log" => log} =
      Map.merge(%{"result" => nil, "error" => nil, "errorDetails" => nil, "log" => nil}, message)

    # debugLogger.log('channel', '<RECV ' + JSON.stringify(message))  -- not ported
    callback = map_get(this, :_callbacks, id)
    if !callback, do: raise("Cannot find command to respond: #{id}")
    map_delete(this, :_callbacks, id)

    if error && !result do
      # Deviation: validated as SerializedError, so that parseError reads atom keys.
      error = ValidatorPrimitives.validate({:type, "SerializedError"}, error, "", _validator_from_wire_context(this))
      parsed_error = Errors.parse_error(error)
      # if (callback.signal?.aborted && parsedError instanceof AbortError) ...  -- not ported: AbortSignal

      parsed_error =
        if is_exception(parsed_error) do
          parsed_error = %{parsed_error | log: log || []}
          parsed_error = Errors.rewrite_error_message(parsed_error, parsed_error.message <> format_call_log(log))

          if details_validator = Validator.maybe_find_validator(callback.type, callback.method, "ErrorDetails"),
            do: %{
              parsed_error
              | details: details_validator.(error_details || %{}, "", _validator_from_wire_context(this))
            },
            else: parsed_error
        else
          parsed_error
        end

      callback.reject.(parsed_error)
    else
      validator = Validator.find_validator(callback.type, callback.method, "Result")
      callback.resolve.(validator.(result, "", _validator_from_wire_context(this)))
    end
  end

  defp _dispatch(this, %{"guid" => guid, "method" => method} = message) do
    params = message["params"]
    # debugLogger.log('channel', '<EVENT ' + JSON.stringify(message))  -- not ported

    if method == "__create__" do
      _create_remote_object(this, guid, params["type"], params["guid"], params["initializer"])
    else
      object = map_get(this, :_objects, guid)
      if !object, do: raise(~s(Cannot find object to "#{method}": #{guid}))

      cond do
        method == "__adopt__" ->
          child = map_get(this, :_objects, params["guid"])
          if !child, do: raise("Unknown new child: #{params["guid"]}")
          ChannelOwner._adopt(object, child)

        method == "__dispose__" ->
          ChannelOwner._dispose(object, params["reason"])

        true ->
          validator = Validator.find_validator(get(object, :_type), method, "Event")

          EventEmitter.emit(
            ChannelOwner._channel(object),
            method,
            validator.(params, "", _validator_from_wire_context(this))
          )
      end
    end
  end

  def close(this, cause \\ nil) do
    if !get(this, :_closedError) do
      put(this, :_closedError, Errors.TargetClosedError.new(cause))
      for callback <- map_values(this, :_callbacks), do: callback.reject.(get(this, :_closedError))
      map_clear(this, :_callbacks)
      emit(this, "close")
      # Elixir only: the heap table is deleted once nothing in it is reachable (PlaywrightEx.Runtime.GC).
      PlaywrightEx.Runtime.GC.close_heap(this)
    end
  end

  # Returns the object itself: channels and owners are the same handle (JS: `object._channel`).
  defp _t_channel_impl_from_wire(this, names, arg, path, _context) do
    case arg do
      %{"guid" => guid} when is_binary(guid) ->
        object = map_get(this, :_objects, guid)
        if !object, do: raise("Object with guid #{guid} was not bound in the connection")

        if names != :* and get(object, :_type) not in names,
          do: raise(ValidationError, message: "#{path}: expected channel #{ChannelOwner.channel_names(names)}")

        object

      _ ->
        raise ValidationError, message: "#{path}: expected channel #{ChannelOwner.channel_names(names)}"
    end
  end

  defp _create_remote_object(this, parent_guid, type, guid, initializer) do
    parent = map_get(this, :_objects, parent_guid)
    if !parent, do: raise("Cannot find parent object #{parent_guid} to create #{guid}")
    validator = Validator.find_validator(type, "", "Initializer")
    initializer = validator.(initializer, "", _validator_from_wire_context(this))
    factory = map_get(this, :_objectFactories, type)
    if !factory, do: raise("Missing type " <> type)
    factory.(parent, type, guid, initializer)
  end

  defp format_call_log(log) do
    if !log or !Enum.any?(log, &(&1 != "")) do
      ""
    else
      # colors.dim(...)  -- not ported
      "\nCall log:\n#{Enum.join(log, "\n")}\n"
    end
  end

  # isomorphic/trace/traceUtils.ts createCallIdGenerator()
  defp create_call_id_generator do
    prefix = for _ <- 1..4, into: "", do: <<Enum.random(?a..?z)>>
    fn -> "#{prefix}@#{System.unique_integer([:positive, :monotonic])}" end
  end
end
