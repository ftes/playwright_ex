defmodule Playwright.Transport.Connection do
  @moduledoc """
  upstream: Transport/Connection.cs

  OTP mapping: the C# `Connection` object becomes a GenServer (owns the transport, the pending
  callbacks and runs `Dispatch`) plus a handle struct (`%Connection{}`) that every ChannelOwner
  carries. `Objects` and all mutable object fields live in a public ETS table owned by the
  GenServer; the event bus is a `Registry`. `SendMessageToServerAsync` runs in the *caller*
  process and blocks on `GenServer.call` until Dispatch replies (C# `await tcs.Task`).
  `ApiZone` (an `AsyncLocal`) maps to the process dictionary.
  """
  use GenServer

  alias Playwright.Core
  alias Playwright.PlaywrightException
  alias Playwright.TargetClosedException
  alias Playwright.TimeoutException
  alias Playwright.Transport.ChannelOwner
  alias Playwright.Transport.Converters
  alias Playwright.Transport.Protocol
  alias Playwright.Transport.StdIOTransport

  defstruct [:pid, :table, :registry, :counter, :call_id_prefix]

  # upstream: Transport/Connection.cs:48
  def error_details_data_key, do: "playwright.errorDetails"
  def log_data_key, do: "playwright.log"

  @api_zone :"$playwright_api_zone"

  # upstream: Transport/Connection.cs:60 (constructor; also wires the transport like Playwright.cs:CreateAsync)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def handle(pid), do: GenServer.call(pid, :handle)

  # upstream: Transport/Connection.cs:84
  def objects(connection), do: :ets.match(connection.table, {{:"$1", :__self__}, :"$2"})

  # upstream: Transport/Connection.cs:88
  def is_remote(connection), do: get_field(connection, :connection, :is_remote, false)

  # upstream: Transport/Connection.cs:98
  def format_call_log(nil), do: ""

  def format_call_log(log) do
    if !Enum.any?(log, &(&1 != nil)) do
      ""
    else
      "\nCall log:\n" <> Enum.join(log, "\n")
    end
  end

  # upstream: Transport/Connection.cs:111
  def dispose(connection), do: GenServer.call(connection.pid, :dispose)

  # upstream: Transport/Connection.cs:129 + :137 (generic overload: `as: Module` converts a ChannelOwner result)
  def send_message_to_server(connection, object, method, args \\ nil, opts \\ []) do
    wrap_api_call(connection, fn -> inner_send_message_to_server(connection, object, method, args, opts) end, false, nil)
  end

  # upstream: Transport/Connection.cs:144
  defp inner_send_message_to_server(connection, object, method, dictionary, opts) do
    keep_nulls = Keyword.get(opts, :keep_nulls, false)
    timeout = opts[:timeout]
    # Fire-and-forget: server intentionally never replies to __waitInfo__,
    # so silently drop it after the connection is closed or the object was collected.
    is_wait_info = method == "__waitInfo__"
    closed_error = get_field(connection, :connection, :closed_error)
    was_collected = object != nil and ChannelOwner.get(object, :was_collected) == true

    cond do
      is_wait_info and (closed_error != nil or was_collected) ->
        nil

      closed_error != nil ->
        raise closed_error

      was_collected ->
        raise PlaywrightException.new("The object has been collected to prevent unbounded heap growth.")

      true ->
        id = "#{connection.call_id_prefix}@#{:atomics.add_get(connection.counter, 1, 1)}"

        sanitized_args =
          for {k, v} <- dictionary || %{}, v != nil, into: %{}, do: {k, v}

        validate_protocol!(object, method, sanitized_args)
        [%{title: title, internal: is_internal, frames: frames}] = Process.get(@api_zone)

        metadata = %{"internal" => is_internal, "wallTime" => System.os_time(:millisecond)}
        metadata = if timeout != nil, do: Map.put(metadata, "timeout", timeout), else: metadata
        metadata = if title not in [nil, ""], do: Map.put(metadata, "title", title), else: metadata

        metadata =
          case frames do
            [frame | _] -> Map.put(metadata, "location", %{"file" => frame.file, "line" => frame.line, "column" => frame.column})
            [] -> metadata
          end

        # skipped: tracing stack (LocalUtils.AddStackToTracingNoReply)

        message = %{
          "id" => id,
          "guid" => if(object, do: object.guid, else: ""),
          "method" => method,
          "params" => sanitized_args,
          "metadata" => metadata
        }

        # _queue.EnqueueAsync(OnMessage) + await tcs.Task: the GenServer serializes sends and replies from Dispatch.
        result = GenServer.call(connection.pid, {:send, id, Converters.to_protocol(message, keep_nulls), is_wait_info}, :infinity)

        # Fire-and-forget: server intentionally never replies to __waitInfo__.
        cond do
          is_wait_info -> nil
          match?({:error, _}, result) -> raise elem(result, 1)
          opts[:as] == nil -> elem(result, 1)
          elem(result, 1) == nil -> nil
          true -> to_channel_owner_result(connection, elem(result, 1))
        end
    end
  end

  defp to_channel_owner_result(connection, result) do
    case Map.values(result) do
      [first | _] -> Converters.to_channel_owner(first, connection)
      [] -> nil
    end
  end

  # upstream: Transport/Connection.cs:255
  def get_object(connection, guid) do
    case :ets.lookup(connection.table, {guid, :__self__}) do
      [{_, object}] -> object
      [] -> nil
    end
  end

  # upstream: Transport/Connection.cs:263
  def initialize_playwright(connection) do
    args = %{"sdkLanguage" => "csharp"}

    json_element = send_message_to_server(connection, nil, "initialize", args)
    Converters.to_channel_owner(json_element["playwright"], connection)
  end

  # upstream: Transport/Connection.cs:274 (runs inside the connection process)
  defp dispatch(state, message) do
    connection = state.handle

    cond do
      get_field(connection, :connection, :closed_error) != nil ->
        state

      message["id"] != nil ->
        {callback, callbacks} = Map.pop(state.callbacks, message["id"])

        if callback == nil do
          raise PlaywrightException.new("Cannot find command to respond: '#{message["id"]}'")
        end

        if message["error"] != nil and message["result"] == nil do
          exception = parse_exception(message["error"]["error"], format_call_log(message["log"]))

          data = %{error_details_data_key() => message["errorDetails"], log_data_key() => message["log"]}
          GenServer.reply(callback, {:error, %{exception | data: data}})
        else
          GenServer.reply(callback, {:ok, message["result"]})
        end

        %{state | callbacks: callbacks}

      true ->
        try do
          dispatch_object_message(connection, message)
          state
        rescue
          ex -> do_close(state, Exception.message(ex))
        end
    end
  end

  defp dispatch_object_message(connection, %{"method" => "__create__"} = message) do
    params = message["params"]
    create_remote_object(connection, message["guid"], params["type"], params["guid"], params["initializer"])
  end

  defp dispatch_object_message(connection, message) do
    object = get_object(connection, message["guid"])

    if object == nil do
      raise PlaywrightException.new("Cannot find object to '#{message["method"]}': '#{message["guid"]}'")
    end

    case message["method"] do
      "__adopt__" ->
        child_guid = message["params"]["guid"]
        child = get_object(connection, child_guid)

        if child == nil do
          raise PlaywrightException.new("Unknown new child: '#{child_guid}'")
        end

        ChannelOwner.adopt(object, child)

      "__dispose__" ->
        ChannelOwner.dispose_owner(object, message["params"]["reason"])

      method ->
        ChannelOwner.on_message(object, method, message["params"])
    end
  end

  # upstream: Transport/Connection.cs:341
  defp create_remote_object(connection, parent_guid, type, guid, initializer) do
    parent = if parent_guid in [nil, ""], do: get_object(connection, ""), else: get_object(connection, parent_guid)

    case type do
      "Artifact" -> Core.Artifact.new(parent, guid, Protocol.ArtifactInitializer.from_json(initializer, connection))
      "Playwright" -> Core.PlaywrightImpl.new(parent, guid, Protocol.PlaywrightInitializer.from_json(initializer, connection))
      "Browser" -> Core.Browser.new(parent, guid, Protocol.BrowserInitializer.from_json(initializer, connection))
      "BrowserType" -> Core.BrowserType.new(parent, guid, Protocol.BrowserTypeInitializer.from_json(initializer, connection))
      "BrowserContext" -> Core.BrowserContext.new(parent, guid, Protocol.BrowserContextInitializer.from_json(initializer, connection))
      "Frame" -> Core.Frame.new(parent, guid, Protocol.FrameInitializer.from_json(initializer, connection))
      "Page" -> Core.Page.new(parent, guid, Protocol.PageInitializer.from_json(initializer, connection))
      "Request" -> Core.Request.new(parent, guid, Protocol.RequestInitializer.from_json(initializer, connection))
      "Response" -> Core.Response.new(parent, guid, Protocol.ResponseInitializer.from_json(initializer, connection))
      # Not ported in this prototype (APIRequestContext, LocalUtils, Tracing, Debugger, ...): inert owners.
      _ -> Core.Unported.new(parent, guid, type)
    end
  end

  # upstream: Transport/Connection.cs:447
  defp do_close(state, cause) do
    do_close_impl(state, if(cause not in [nil, ""], do: TargetClosedException.new(cause), else: TargetClosedException.new()))
  end

  # upstream: Transport/Connection.cs:447
  defp do_close_impl(state, close_error) do
    set_field(state.handle, :connection, :closed_error, close_error)
    dispose_impl(state)
  end

  # upstream: Transport/Connection.cs:460
  defp create_call_id_prefix do
    alphabet = ~c"abcdefghijklmnopqrstuvwxyz"
    for <<b <- :crypto.strong_rand_bytes(4)>>, into: "", do: <<Enum.at(alphabet, rem(b, 26))>>
  end

  # upstream: Transport/Connection.cs:472
  defp parse_exception(error, message_suffix) do
    cond do
      error["message"] in [nil, ""] -> PlaywrightException.new(inspect(error["value"]))
      error["name"] == "TimeoutError" -> TimeoutException.new(error["message"] <> message_suffix)
      error["name"] == "TargetClosedError" -> TargetClosedException.new(error["message"] <> message_suffix)
      true -> PlaywrightException.new(error["message"] <> message_suffix)
    end
  end

  # upstream: Transport/Connection.cs:491
  defp dispose_impl(%{disposed: true} = state), do: state

  defp dispose_impl(state) do
    closed_error = get_field(state.handle, :connection, :closed_error) || TargetClosedException.new("Connection disposed")
    set_field(state.handle, :connection, :closed_error, closed_error)

    for {_id, callback} <- state.callbacks do
      GenServer.reply(callback, {:error, closed_error})
    end

    if state.transport, do: StdIOTransport.close(state.transport)
    ChannelOwner.emit(get_object(state.handle, ""), "Close", TargetClosedException.new("Connection disposed"))
    %{state | disposed: true, callbacks: %{}, transport: nil}
  end

  # upstream: Transport/Connection.cs:514
  defp trace_message(log_level, raw_message) do
    actual_log_level = System.get_env("DEBUG")

    if actual_log_level not in [nil, ""] and String.contains?(actual_log_level, log_level) do
      IO.puts(:stderr, "#{log_level}: #{JSON.encode!(raw_message)}")
    end
  end

  # upstream: Transport/Connection.cs:532
  def wrap_api_call(_connection, action, is_internal \\ false, title \\ nil) do
    ensure_api_zone_exists()

    if hd(Process.get(@api_zone)) != nil do
      action.()
    else
      {:current_stacktrace, st} = Process.info(self(), :current_stacktrace)

      stack =
        for {mod, _fun, _arity, location} <- st,
            not is_playwright_internal_namespace(mod) and location[:file] != nil,
            do: %{file: Path.expand(to_string(location[:file])), line: location[:line], column: 0}

      try do
        Process.put(@api_zone, [%{internal: is_internal, title: title, frames: stack}])
        action.()
      after
        Process.put(@api_zone, [nil])
      end
    end
  end

  # upstream: Transport/Connection.cs:571
  defp is_playwright_internal_namespace(mod) do
    name = Atom.to_string(mod)
    String.starts_with?(name, "Elixir.Playwright.") or mod in [Process, ExUnit.Runner] or not String.starts_with?(name, "Elixir.")
  end

  # upstream: Transport/Connection.cs:580
  defp ensure_api_zone_exists do
    if Process.get(@api_zone) == nil, do: Process.put(@api_zone, [nil])
  end

  # ---- Elixir-only: field storage (C# object fields; see ChannelOwner) ---------------------

  def put_object(connection, guid, object), do: :ets.insert(connection.table, {{guid, :__self__}, object})
  def remove_object(connection, guid), do: :ets.delete(connection.table, {guid, :__self__})

  def get_field(connection, guid, field, default \\ nil) do
    case :ets.lookup(connection.table, {guid, field}) do
      [{_, value}] -> value
      [] -> default
    end
  end

  def set_field(connection, guid, field, value), do: :ets.insert(connection.table, {{guid, field}, value})

  # ---- Elixir-only: validation of hand-written Core args against the generated protocol ----

  defp validate_protocol!(object, method, args) do
    if Application.get_env(:playwright_dotnet_port, :validate_protocol, false) and not String.starts_with?(method, "__") do
      interface = interface_name(object)

      case Protocol.Commands.params(interface, method) do
        :unknown -> raise PlaywrightException.new("Protocol has no command #{interface}.#{method}")
        known -> for k <- Map.keys(args), k not in known, do: raise(PlaywrightException.new("Protocol: #{interface}.#{method} has no param #{k}"))
      end
    end
  end

  defp interface_name(nil), do: "Root"
  defp interface_name(%Core.PlaywrightImpl{}), do: "Playwright"
  defp interface_name(%Core.Unported{type: type}), do: type
  defp interface_name(%mod{}), do: mod |> Module.split() |> List.last()

  # ---- GenServer -------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    registry_name = :"#{__MODULE__}.Registry.#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

    handle = %__MODULE__{
      pid: self(),
      table: table,
      registry: registry_name,
      counter: :atomics.new(1, []),
      call_id_prefix: create_call_id_prefix()
    }

    # _rootObject = new(null, this, string.Empty);
    ChannelOwner.new(Core.Unported, nil, handle, "", type: "Root")
    {:ok, transport} = StdIOTransport.start_link(Keyword.put(opts, :owner, self()))
    {:ok, %{handle: handle, callbacks: %{}, transport: transport, disposed: false}}
  end

  @impl GenServer
  def handle_call(:handle, _from, state), do: {:reply, state.handle, state}

  def handle_call(:dispose, _from, state), do: {:reply, :ok, dispose_impl(state)}

  def handle_call({:send, id, message, is_wait_info}, from, state) do
    cond do
      state.transport == nil ->
        {:reply, {:error, get_field(state.handle, :connection, :closed_error)}, state}

      is_wait_info ->
        on_message(state, message)
        {:reply, {:ok, nil}, state}

      true ->
        on_message(state, message)
        {:noreply, %{state | callbacks: Map.put(state.callbacks, id, from)}}
    end
  end

  # Playwright.cs: connection.OnMessage = message => transport.SendAsync(message)
  defp on_message(state, message) do
    trace_message("pw:channel:send", message)
    StdIOTransport.send_async(state.transport, message)
  end

  @impl GenServer
  def handle_info({:transport_message, message}, state) do
    trace_message("pw:channel:recv", message)
    {:noreply, dispatch(state, message)}
  end

  # Playwright.cs: transport.TransportClosed += (_, reason) => connection.DoClose(reason)
  def handle_info({:transport_closed, reason}, state), do: {:noreply, do_close(state, reason)}
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
end
