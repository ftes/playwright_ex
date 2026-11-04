defmodule Playwright.Impl.Connection do
  # upstream: Connection.java:61
  # OTP mapping of Java's single-threaded message pump:
  # * This module is a GenServer that owns the transport and runs `dispatch` for every incoming message
  #   (object creation, `handleEvent`, completing callbacks) -- what Java does inside `processOneMessage()`.
  # * Client processes block in `run_until/3`; their pump (`process_one_message/1`) only executes work that the
  #   Connection routed to them ({:playwright_run, fun}: listener calls, wake-ups), like Java's user thread.
  # * Handle struct fields below are final; mutable fields (`objects`, `callbacks`, `lastId`, `playwright`,
  #   `localUtils`) live in the Heap, `title`/`titleReported` are per calling process (Java: per thread).
  use GenServer
  import Playwright.Impl.Heap, only: [get: 2, put: 3]

  alias Playwright.Impl.{
    APIRequestContextImpl,
    ArtifactImpl,
    BrowserContextImpl,
    BrowserImpl,
    BrowserTypeImpl,
    ChannelOwner,
    DebuggerImpl,
    ElementHandleImpl,
    FrameImpl,
    Heap,
    JSHandleImpl,
    LocalUtils,
    PageImpl,
    PipeTransport,
    PlaywrightImpl,
    Protocol.SerializedError,
    RequestImpl,
    ResponseImpl,
    ServerErrorWithDetails,
    Stream,
    TargetClosedError,
    TracingImpl,
    UnportedObject,
    WaitableResult,
    DriverException
  }

  alias Playwright.{PlaywrightException, TimeoutError}

  defmodule Message do
    # upstream: Connection.java:37
    defstruct [:id, :guid, :method, :params, :result, :error, :error_details, :log]
  end

  defstruct [:id, :pid, :env, :is_remote, :call_id_prefix]

  @driver_response_grace_ms 10_000

  defmodule Root do
    # upstream: Connection.java:84
    use Playwright.Impl.ChannelOwner

    # upstream: Connection.java:85
    def new(connection), do: ChannelOwner.init(__MODULE__, connection, "Root", "")

    # upstream: Connection.java:89
    def initialize(this) do
      params = %{"sdkLanguage" => "java"}
      result = send_message(this, "initialize", params, @no_timeout)
      Connection.get_existing_object(this.connection, result["playwright"]["guid"])
    end
  end

  # upstream: Connection.java:102
  # Java receives a constructed Transport; a Port must be opened by its owning process, so the GenServer opens it.
  def new(transport_command, env), do: new(transport_command, env, false)

  # upstream: Connection.java:106
  defp new(transport_command, env, is_remote) do
    this = %__MODULE__{id: make_ref(), env: env, is_remote: is_remote, call_id_prefix: create_call_id_prefix()}
    {:ok, pid} = GenServer.start_link(__MODULE__, {this, transport_command})
    this = %{this | pid: pid}
    put(this, :root, Root.new(this))
    this
  end

  # upstream: Connection.java:117
  defp create_call_id_prefix do
    alphabet = ~c"abcdefghijklmnopqrstuvwxyz"
    for _ <- 1..4, into: "", do: <<Enum.random(alphabet)>>
  end

  # upstream: Connection.java:134
  def set_title(this, new_title) do
    {previous, _title_reported} = Process.get({:playwright_title, this.id}, {nil, false})
    Process.put({:playwright_title, this.id}, {new_title, false})
    previous
  end

  # upstream: Connection.java:141
  def close(this), do: GenServer.stop(this.pid)

  # upstream: Connection.java:149
  def send_message(this, guid, method, params), do: send_message(this, guid, method, params, nil)

  # upstream: Connection.java:149
  def send_message(this, guid, method, params, timeout) do
    if self() == this.pid, do: raise(PlaywrightException, message: "Blocking call #{method} from dispatch")
    result = internal_send_message(this, guid, method, params, timeout, true, true)

    if timeout == nil or timeout == 0 do
      ChannelOwner.run_until(get(this, :root), fn -> nil end, result)
    else
      # The driver enforces the timeout, but the driver itself may hang.
      deadline = System.monotonic_time(:millisecond) + trunc(timeout) + @driver_response_grace_ms

      while(fn -> !WaitableResult.is_done(result) end, fn ->
        if !process_one_message(this) and System.monotonic_time(:millisecond) - deadline > 0 do
          WaitableResult.complete_exceptionally(result, %TimeoutError{
            message:
              "Timeout #{trunc(timeout)}ms exceeded while waiting for the driver to respond to " <>
                method <> ". The driver is not responding."
          })
        end
      end)

      try do
        WaitableResult.get(result)
      after
        WaitableResult.dispose(result)
      end
    end
  end

  # upstream: Connection.java:165
  def send_message_async(this, guid, method, params) do
    internal_send_message(this, guid, method, params, nil, true, true)
  end

  # upstream: Connection.java:170
  # Fire-and-forget: the server never replies.
  def send_message_no_reply(this, guid, method, params) do
    internal_send_message(this, guid, method, params, nil, false, false)
  end

  # upstream: Connection.java:174
  defp internal_send_message(this, guid, method, params, timeout, _send_stack, expects_reply) do
    id = this.call_id_prefix <> "@" <> Integer.to_string(Heap.counter({this.id, :last_id}))
    result = WaitableResult.new()
    if expects_reply, do: Heap.put_raw({this.id, :callback, id}, result)
    message = %{"id" => id, "guid" => guid, "method" => method, "params" => params}
    metadata = %{"wallTime" => System.system_time(:millisecond)}
    metadata = if timeout != nil, do: Map.put(metadata, "timeout", timeout), else: metadata
    {title, title_reported} = Process.get({:playwright_title, this.id}, {nil, false})

    metadata =
      if title_reported do
        Map.put(metadata, "internal", true)
      else
        if title != nil do
          # All but first message in a custom-titled API call are considered internal and will be hidden from the inspector.
          Process.put({:playwright_title, this.id}, {title, true})
          Map.put(metadata, "title", title)
        else
          metadata
        end

        # StackTraceCollector (location metadata) and tracing stacks: not ported.
      end

    message = Map.put(message, "metadata", metadata)
    GenServer.cast(this.pid, {:send, message})
    result
  end

  # upstream: Connection.java:225
  def initialize_playwright(this) do
    playwright = Root.initialize(get(this, :root))
    put(this, :playwright, playwright)
  end

  # upstream: Connection.java:230
  def local_utils(this), do: get(this, :local_utils)

  # upstream: Connection.java:234
  def get_existing_object(this, guid) do
    result = Heap.get_raw({this.id, :object, guid})
    if result == nil, do: raise(PlaywrightException, message: "Object doesn't exist: " <> guid)
    result
  end

  # upstream: Connection.java:241
  def register_object(this, guid, object), do: Heap.put_raw({this.id, :object, guid}, object)

  # upstream: Connection.java:245
  def unregister_object(this, guid), do: Heap.delete_raw({this.id, :object, guid})

  # upstream: Connection.java:249
  # Client-side pump: Java polls the transport for 10ms and dispatches; here the Connection process already
  # dispatched, so the client only runs the work routed to it.
  def process_one_message(_this) do
    receive do
      {:playwright_run, fun} ->
        fun.()
        true
    after
      10 -> false
    end
  end

  # upstream: Connection.java:260
  defp format_call_log(log) do
    if log == nil or Enum.all?(log, &(&1 == "")) do
      ""
    else
      lines = ["", "Call log:"] ++ Enum.map(log, &("- " <> &1)) ++ [""]
      Enum.join(lines, "\n")
    end
  end

  # upstream: Connection.java:284
  defp dispatch(this, message) do
    cond do
      message.id != nil ->
        callback = Heap.get_raw({this.id, :callback, message.id})

        if callback == nil,
          do: raise(PlaywrightException, message: "Cannot find command to respond: " <> message.id)

        Heap.delete_raw({this.id, :callback, message.id})

        if message.error == nil do
          WaitableResult.complete(callback, message.result)
        else
          call_log = format_call_log(message.log)

          exception =
            cond do
              message.error.error == nil ->
                %PlaywrightException{message: to_string(message.error) <> call_log}

              "TimeoutError" == message.error.error.name ->
                %TimeoutError{message: to_string(message.error.error) <> call_log}

              "TargetClosedError" == message.error.error.name ->
                TargetClosedError.exception(to_string(message.error.error) <> call_log)

              true ->
                %DriverException{message: to_string(message.error.error) <> call_log}
            end

          exception =
            if message.error_details != nil,
              do: ServerErrorWithDetails.new(exception, message.error_details, message.log),
              else: exception

          WaitableResult.complete_exceptionally(callback, exception)
        end

      # TODO: throw?
      message.method == nil ->
        nil

      message.method == "__create__" ->
        create_remote_object(this, message.guid, message.params)

      true ->
        object = Heap.get_raw({this.id, :object, message.guid})

        if object == nil,
          do: raise(PlaywrightException, message: "Cannot find object to call #{message.method}: #{message.guid}")

        cond do
          message.method == "__adopt__" ->
            child_guid = message.params["guid"]
            child = Heap.get_raw({this.id, :object, child_guid})
            if child == nil, do: raise(PlaywrightException, message: "Unknown new child:  " <> child_guid)
            ChannelOwner.adopt(object, child)

          message.method == "__dispose__" ->
            was_collected = message.params["reason"] == "gc"
            ChannelOwner.dispose_channel_owner(object, was_collected)

          true ->
            object.__struct__.handle_event(object, message.method, message.params)
        end
    end
  end

  # upstream: Connection.java:345
  defp create_remote_object(this, parent_guid, params) do
    type = params["type"]
    guid = params["guid"]

    parent = Heap.get_raw({this.id, :object, parent_guid})

    if parent == nil,
      do: raise(PlaywrightException, message: "Cannot find parent object #{parent_guid} to create #{guid}")

    initializer = params["initializer"]

    case type do
      "Artifact" -> ArtifactImpl.new(parent, type, guid, initializer)
      "BrowserType" -> BrowserTypeImpl.new(parent, type, guid, initializer)
      "Browser" -> BrowserImpl.new(parent, type, guid, initializer)
      "BrowserContext" -> BrowserContextImpl.new(parent, type, guid, initializer)
      "ElementHandle" -> ElementHandleImpl.new(parent, type, guid, initializer)
      "APIRequestContext" -> APIRequestContextImpl.new(parent, type, guid, initializer)
      "Frame" -> FrameImpl.new(parent, type, guid, initializer)
      "JSHandle" -> JSHandleImpl.new(parent, type, guid, initializer)
      "LocalUtils" -> create_local_utils(this, parent, type, guid, initializer)
      "Page" -> PageImpl.new(parent, type, guid, initializer)
      "Playwright" -> PlaywrightImpl.new(parent, type, guid, initializer)
      "Request" -> RequestImpl.new(parent, type, guid, initializer)
      "Response" -> ResponseImpl.new(parent, type, guid, initializer)
      "Stream" -> Stream.new(parent, type, guid, initializer)
      "Debugger" -> DebuggerImpl.new(parent, type, guid, initializer)
      "Tracing" -> TracingImpl.new(parent, type, guid, initializer)
      # Remaining upstream cases (BindingCall, Dialog, Route, WebSocket, Worker, ...) are not ported.
      _ -> UnportedObject.new(parent, type, guid, initializer)
    end
  end

  defp create_local_utils(this, parent, type, guid, initializer) do
    result = LocalUtils.new(parent, type, guid, initializer)
    if local_utils(this) == nil, do: put(this, :local_utils, result)
    result
  end

  # Elixir has no `while`; used for Java `while (cond) { body }` loops.
  def while(condition, body) do
    if condition.() do
      body.()
      while(condition, body)
    end
  end

  ## GenServer (no upstream counterpart: the "message pump" thread)

  @impl GenServer
  def init({this, transport_command}) do
    {:ok, %{connection: this, transport: PipeTransport.open(transport_command, this.env)}}
  end

  @impl GenServer
  def handle_cast({:send, message}, state) do
    PipeTransport.send(state.transport, message)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{transport: %{port: port}} = state) do
    {transport, messages} = PipeTransport.receive_data(state.transport, data)
    for message <- messages, do: dispatch(state.connection, to_message(message))
    {:noreply, %{state | transport: transport}}
  end

  def handle_info({port, {:exit_status, status}}, %{transport: %{port: port}} = state) do
    {:stop, {:driver_exited, status}, state}
  end

  @impl GenServer
  def terminate(_reason, state), do: PipeTransport.close(state.transport)

  defp to_message(json) do
    %Message{
      id: json["id"],
      guid: json["guid"],
      method: json["method"],
      params: json["params"],
      result: json["result"],
      error: json["error"] && SerializedError.from_json(json["error"]),
      error_details: json["errorDetails"],
      log: json["log"]
    }
  end
end
