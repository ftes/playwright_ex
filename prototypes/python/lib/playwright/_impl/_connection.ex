# upstream: playwright/_impl/_connection.py
alias Asyncio.Future
alias Playwright.Impl.Connection
alias Playwright.Impl.Connection.{Channel, ChannelOwner, ProtocolCallback, RootChannelOwner}
alias Playwright.Impl.Errors
alias Playwright.Impl.Errors.{Error, TargetClosedError}
alias Playwright.Impl.Helper

defmodule Playwright.Impl.Connection.Channel do
  # class Channel(AsyncIOEventEmitter)
  use Pyee.EventEmitter

  # upstream: _connection.py:63
  def init(connection, object) do
    self = Py.new(__MODULE__)
    Py.set(self, :_connection, connection)
    Py.set(self, :_guid, object[:_guid])
    Py.set(self, :_object, object)
    on(self, "error", fn exc -> Connection._on_event_listener_error(self[:_connection], exc) end)
    self
  end

  # upstream: _connection.py:70
  def send(self, method, timeout_calculator, params \\ nil, is_internal \\ false, title \\ nil) do
    Connection.wrap_api_call(
      self[:_connection],
      fn -> _inner_send(self, method, timeout_calculator, params, false) end,
      is_internal,
      title
    )
  end

  # upstream: _connection.py:84
  def send_may_fail(
        self,
        method,
        timeout_calculator,
        params \\ nil,
        is_internal \\ false,
        title \\ nil
      ) do
    Helper.create_task_and_ignore_exception(
      self[:_connection][:_loop],
      fn -> send(self, method, timeout_calculator, params, is_internal, title) end
    )
  end

  # upstream: _connection.py:97
  def send_return_as_dict(
        self,
        method,
        timeout_calculator,
        params \\ nil,
        is_internal \\ false,
        title \\ nil
      ) do
    Connection.wrap_api_call(
      self[:_connection],
      fn -> _inner_send(self, method, timeout_calculator, params, true) end,
      is_internal,
      title
    )
  end

  # upstream: _connection.py:111
  def send_no_reply(
        self,
        method,
        timeout_calculator,
        params \\ nil,
        is_internal \\ false,
        title \\ nil
      ) do
    # No reply messages are used to e.g. __waitInfo__(after).
    {augmented_params, timeout} = Connection._augment_params(params, timeout_calculator)

    Connection.wrap_api_call_sync(
      self[:_connection],
      fn ->
        Connection._send_message_to_server(
          self[:_connection],
          self[:_object],
          method,
          augmented_params,
          timeout,
          true
        )
      end,
      is_internal,
      title
    )
  end

  # upstream: _connection.py:133
  def _inner_send(self, method, timeout_calculator, params, return_as_dict) do
    if self[:_connection][:_error] do
      error = self[:_connection][:_error]
      Py.set(self[:_connection], :_error, nil)
      raise error
    end

    {augmented_params, timeout} = Connection._augment_params(params, timeout_calculator)

    callback =
      Connection._send_message_to_server(
        self[:_connection],
        self[:_object],
        method,
        augmented_params,
        timeout
      )

    # asyncio.CancelledError -> _abort(): no counterpart, a blocked BEAM process is
    # cancelled by being killed (see report).
    {done, _} =
      Asyncio.wait_first_completed([
        self[:_connection][:_transport][:on_error_future],
        callback.future
      ])

    if not Future.done(callback.future), do: Future.cancel(callback.future)
    result = Future.result(hd(done))
    # Protocol now has named return values, assume result is one level deeper unless
    # there is explicit ambiguity.
    cond do
      !result ->
        nil

      return_as_dict ->
        result

      map_size(result) == 0 ->
        nil

      true ->
        1 = map_size(result)
        [key] = Map.keys(result)
        result[key]
    end
  end
end

defmodule Playwright.Impl.Connection.ChannelOwner do
  # class ChannelOwner(AsyncIOEventEmitter); `use ChannelOwner` == subclassing it.

  # upstream: _connection.py:181
  def init(self, parent, type, guid, initializer) do
    # super().__init__(loop=parent._loop)
    Py.set(self, :_loop, parent[:_loop])
    Py.set(self, :_dispatcher_fiber, parent[:_dispatcher_fiber])
    Py.set(self, :_type, type)
    Py.set(self, :_guid, guid)

    Py.set(
      self,
      :_connection,
      if(is_channel_owner(parent), do: parent[:_connection], else: parent)
    )

    Py.set(self, :_parent, if(is_channel_owner(parent), do: parent, else: nil))
    Py.set(self, :_objects, %{})
    Py.set(self, :_channel, Channel.init(self[:_connection], self))
    Py.set(self, :_initializer, initializer)
    Py.set(self, :_was_collected, false)

    Py.set(self[:_connection], :_objects, Map.put(self[:_connection][:_objects], guid, self))

    if self[:_parent],
      do: Py.set(self[:_parent], :_objects, Map.put(self[:_parent][:_objects], guid, self))

    Py.set(self, :_event_to_subscription_mapping, %{})
    self
  end

  # isinstance(parent, ChannelOwner)
  def is_channel_owner(%Connection{}), do: false
  def is_channel_owner(_), do: true

  # upstream: _connection.py:210
  def _dispose(self, reason) do
    # Clean up from parent and connection.
    if self[:_parent],
      do: Py.set(self[:_parent], :_objects, Map.delete(self[:_parent][:_objects], self[:_guid]))

    Py.set(self[:_connection], :_objects, Map.delete(self[:_connection][:_objects], self[:_guid]))
    Py.set(self, :_was_collected, reason == "gc")

    # Dispose all children.
    for object <- Map.values(self[:_objects]), do: object.__struct__._dispose(object, reason)
    Py.set(self, :_objects, %{})
  end

  # upstream: _connection.py:222
  def _adopt(self, child) do
    Py.set(child[:_parent], :_objects, Map.delete(child[:_parent][:_objects], child[:_guid]))
    Py.set(self, :_objects, Map.put(self[:_objects], child[:_guid], child))
    Py.set(child, :_parent, self)
  end

  # upstream: _connection.py:227
  def _set_event_to_subscription_mapping(self, mapping) do
    Py.set(self, :_event_to_subscription_mapping, mapping)
  end

  # upstream: _connection.py:230
  def _update_subscription(self, event, enabled) do
    protocol_event = self[:_event_to_subscription_mapping][event]

    if protocol_event do
      Connection.wrap_api_call_sync(
        self[:_connection],
        fn ->
          Channel.send_no_reply(self[:_channel], "updateSubscription", nil, %{
            "event" => protocol_event,
            "enabled" => enabled
          })
        end,
        true
      )
    end
  end

  # upstream: _connection.py:242
  def _add_event_handler(self, event, k, v) do
    if Pyee.EventEmitter.listeners(self, event) == [], do: _update_subscription(self, event, true)
    Pyee.EventEmitter._add_event_handler(self, event, k, v)
  end

  # upstream: _connection.py:247
  def remove_listener(self, event, f) do
    Pyee.EventEmitter.remove_listener(self, event, f)

    if Pyee.EventEmitter.listeners(self, event) == [],
      do: _update_subscription(self, event, false)
  end

  defmacro __using__(_) do
    quote do
      use Pyee.EventEmitter
      defdelegate _add_event_handler(self, event, k, v), to: ChannelOwner
      defdelegate remove_listener(self, event, f), to: ChannelOwner
      defdelegate _dispose(self, reason), to: ChannelOwner
      defdelegate _adopt(self, child), to: ChannelOwner
      defdelegate _set_event_to_subscription_mapping(self, mapping), to: ChannelOwner
      defdelegate _update_subscription(self, event, enabled), to: ChannelOwner
      defoverridable _dispose: 2
    end
  end
end

defmodule Playwright.Impl.Connection.ProtocolCallback do
  defstruct [:id, :stack_trace, :no_reply, :future]

  # upstream: _connection.py:254
  def init(_loop, id, no_reply \\ false) do
    self = %__MODULE__{id: id}
    self = %{self | stack_trace: nil}
    self = %{self | no_reply: no_reply}
    self = %{self | future: Future.new()}
    if no_reply, do: Future.set_result(self.future, nil)

    # The outer task can get cancelled by the user, this forwards the cancellation to the inner task.
    # (current_task done-callback plumbing omitted: no task cancellation on the BEAM)
    self
  end
end

defmodule Playwright.Impl.Connection.RootChannelOwner do
  use ChannelOwner

  # upstream: _connection.py:282
  def init(connection), do: ChannelOwner.init(Py.new(__MODULE__), connection, "Root", "", %{})

  # upstream: _connection.py:285
  def initialize(self) do
    Connection.from_channel(
      Channel.send(self[:_channel], "initialize", nil, %{"sdkLanguage" => "python"})
    )
  end
end

defmodule Playwright.Impl.Connection do
  # class Connection(EventEmitter) + the module-level functions of _connection.py
  use Pyee.EventEmitter
  alias Playwright.Impl.Transport.PipeTransport

  # upstream: _connection.py:298
  def init(dispatcher_fiber, object_factory, transport, loop, local_utils \\ nil) do
    self = Py.new(__MODULE__)
    Py.set(self, :_dispatcher_fiber, dispatcher_fiber)
    Py.set(self, :_transport, transport)
    Py.set(self[:_transport], :on_message, fn msg -> dispatch(self, msg) end)
    # Call ids double as trace call ids, so they must be unique across connections.
    Py.set(self, :_call_id_prefix, for(_ <- 1..4, into: "", do: <<Enum.random(?a..?z)>>))
    Py.set(self, :_last_id, 0)
    Py.set(self, :_objects, %{})
    Py.dict_clear(self, :_callbacks)
    Py.set(self, :_object_factory, object_factory)
    Py.set(self, :_is_sync, false)
    Py.set(self, :_child_ws_connections, [])
    Py.set(self, :_loop, loop)
    Py.set(self, :playwright_future, Future.new())
    Py.set(self, :_error, nil)
    Py.set(self, :is_remote, false)
    Py.set(self, :_init_task, nil)
    # contextvars.ContextVar("ApiZone") -> process dictionary key
    Py.set(self, :_api_zone, {:api_zone, self.__id__})
    Py.set(self, :_local_utils, local_utils)
    Py.set(self, :_tracing_count, 0)
    Py.set(self, :_closed_error, nil)
    self
  end

  # upstream: _connection.py:331
  def local_utils(self) do
    true = self[:_local_utils] != nil
    self[:_local_utils]
  end

  # upstream: _connection.py:335
  def mark_as_remote(self), do: Py.set(self, :is_remote, true)

  # upstream: _connection.py:338
  def run_as_sync(self) do
    Py.set(self, :_is_sync, true)
    run(self)
  end

  # upstream: _connection.py:342
  def run(self) do
    Py.set(self, :_loop, self())
    Py.set(self, :_root_object, RootChannelOwner.init(self))

    init = fn ->
      try do
        result = RootChannelOwner.initialize(self[:_root_object])

        if not Future.done(self[:playwright_future]),
          do: Future.set_result(self[:playwright_future], result)
      rescue
        exc ->
          # No re-raise: callers observe playwright_future.
          if not Future.done(self[:playwright_future]),
            do: Future.set_exception(self[:playwright_future], exc)
      end
    end

    PipeTransport.connect(self[:_transport])
    Py.set(self, :_init_task, Asyncio.create_task(init))
    PipeTransport.run(self[:_transport])
  end

  # upstream: _connection.py:362
  def stop_sync(self) do
    PipeTransport.request_stop(self[:_transport])
    # self._dispatcher_fiber.switch() -- no greenlets
    PipeTransport.wait_until_stopped(self[:_transport])
    cleanup(self)
  end

  # upstream: _connection.py:368
  def stop_async(self), do: stop_sync(self)

  # upstream: _connection.py:373
  def cleanup(self, cause \\ nil) do
    Py.set(
      self,
      :_closed_error,
      if(cause, do: TargetClosedError.new(cause), else: TargetClosedError.new())
    )

    if self[:_init_task] && not Asyncio.Task.done(self[:_init_task]),
      do: Asyncio.Task.cancel(self[:_init_task])

    for ws_connection <- self[:_child_ws_connections],
        do: PipeTransport.dispose(ws_connection[:_transport])

    for callback <- Py.dict_values(self, :_callbacks) do
      # To prevent 'Future exception was never retrieved' we ignore all callbacks that are no_reply.
      cond do
        callback.no_reply -> :ok
        Future.cancelled(callback.future) -> :ok
        true -> Future.set_exception(callback.future, self[:_closed_error])
      end
    end

    Py.dict_clear(self, :_callbacks)
    emit(self, "close")
  end

  # upstream: _connection.py:389
  def set_is_tracing(self, is_tracing) do
    if is_tracing,
      do: Py.set(self, :_tracing_count, self[:_tracing_count] + 1),
      else: Py.set(self, :_tracing_count, self[:_tracing_count] - 1)
  end

  # upstream: _connection.py:395
  def _send_message_to_server(self, object, method, params, timeout, no_reply \\ false) do
    if self[:_closed_error], do: raise(self[:_closed_error])

    if object[:_was_collected],
      do: raise(Error.new("The object has been collected to prevent unbounded heap growth."))

    last_id = Py.incr(self, :_last_id)
    id = "#{self[:_call_id_prefix]}@#{last_id}"
    callback = ProtocolCallback.init(self[:_loop], id, no_reply)
    {:current_stacktrace, task_stack} = Process.info(self(), :current_stacktrace)
    callback = %{callback | stack_trace: task_stack}
    callback = %{callback | no_reply: no_reply}
    stack_trace_information = Process.get(self[:_api_zone])
    frames = stack_trace_information["frames"] || []

    location =
      if frames != [] do
        %{
          "file" => hd(frames)["file"],
          "line" => hd(frames)["line"],
          "column" => hd(frames)["column"]
        }
      end

    metadata = %{
      "wallTime" => System.os_time(:millisecond),
      "apiName" => stack_trace_information["apiName"],
      "internal" => not Py.bool(stack_trace_information["apiName"]),
      "timeout" => timeout
    }

    metadata = if location, do: Map.put(metadata, "location", location), else: metadata
    title = stack_trace_information["title"]
    metadata = if title, do: Map.put(metadata, "title", title), else: metadata

    message = %{
      "id" => id,
      "guid" => object[:_guid],
      "method" => method,
      "params" => _replace_channels_with_guids(self, params),
      "metadata" => metadata
    }

    # (tracing stack upload via local_utils omitted)

    # DEVIATION (order swapped): asyncio is single-threaded so upstream can send
    # first and register after; on the BEAM the dispatcher may see the reply first.
    Py.dict_put(self, :_callbacks, id, callback)
    PipeTransport.send(self[:_transport], message)

    callback
  end

  # upstream: _connection.py:484
  def dispatch(self, msg) do
    id = msg["id"]

    cond do
      self[:_closed_error] ->
        nil

      id ->
        callback = Py.dict_pop(self, :_callbacks, id)

        cond do
          Future.cancelled(callback.future) ->
            nil

          # No reply messages are used to e.g. __waitInfo__(after) which returns exceptions on page close.
          # To prevent 'Future exception was never retrieved' we just ignore such messages.
          callback.no_reply ->
            nil

          true ->
            error = msg["error"]

            if error && !msg["result"] do
              parsed_error = Helper.parse_error(error["error"], format_call_log(msg["log"]))
              parsed_error = %{parsed_error | _log: msg["log"]}

              parsed_error = %{
                parsed_error
                | _details: _replace_guids_with_channels(self, msg["errorDetails"])
              }

              parsed_error = %{
                parsed_error
                | _stack: Exception.format_stacktrace(callback.stack_trace)
              }

              Future.set_exception(callback.future, parsed_error)
            else
              result = _replace_guids_with_channels(self, msg["result"])
              Future.set_result(callback.future, result)
            end
        end

      true ->
        guid = msg["guid"]
        method = msg["method"]
        params = msg["params"]

        if method == "__create__" do
          true = params != nil
          parent = self[:_objects][guid]

          _create_remote_object(
            self,
            parent,
            params["type"],
            params["guid"],
            params["initializer"]
          )
        else
          object = self[:_objects][guid]
          if !object, do: raise(~s(Cannot find object to "#{method}": #{guid}))

          cond do
            method == "__adopt__" ->
              child_guid = params["guid"]
              child = self[:_objects][child_guid]
              if !child, do: raise("Unknown new child: #{child_guid}")
              object.__struct__._adopt(object, child)

            method == "__dispose__" ->
              true = is_map(params)
              obj = self[:_objects][guid]
              obj.__struct__._dispose(obj, params["reason"])

            true ->
              object = self[:_objects][guid]
              should_replace_guids_with_channels = not String.contains?(guid, "jsonPipe@")

              try do
                # self._is_sync greenlet branch: listeners simply run inline here.
                if should_replace_guids_with_channels do
                  Channel.emit(
                    object[:_channel],
                    method,
                    _replace_guids_with_channels(self, params)
                  )
                else
                  Channel.emit(object[:_channel], method, params)
                end
              rescue
                exc -> _on_event_listener_error(self, exc)
              end
          end
        end
    end
  end

  # upstream: _connection.py:574
  def _on_event_listener_error(self, exc) do
    IO.puts(:stderr, "Error occurred in event listener")
    IO.puts(:stderr, Exception.format(:error, exc))

    # Save the error to throw at the next API call. This "replicates" unhandled rejection in Node.js.
    Py.set(self, :_error, exc)
  end

  # upstream: _connection.py:580
  def _create_remote_object(self, parent, type, guid, initializer) do
    initializer = _replace_guids_with_channels(self, initializer)
    self[:_object_factory].(parent, type, guid, initializer)
  end

  # upstream: _connection.py:586
  def _replace_channels_with_guids(self, payload) do
    cond do
      payload == nil ->
        payload

      is_list(payload) ->
        Enum.map(payload, &_replace_channels_with_guids(self, &1))

      is_struct(payload, Channel) ->
        %{"guid" => payload[:_guid]}

      is_map(payload) and not is_struct(payload) ->
        Map.new(payload, fn {key, value} -> {key, _replace_channels_with_guids(self, value)} end)

      true ->
        payload
    end
  end

  # upstream: _connection.py:607
  def _replace_guids_with_channels(self, payload) do
    cond do
      payload == nil ->
        payload

      is_list(payload) ->
        Enum.map(payload, &_replace_guids_with_channels(self, &1))

      is_map(payload) ->
        if Map.has_key?(self[:_objects], payload["guid"]) do
          self[:_objects][payload["guid"]][:_channel]
        else
          Map.new(payload, fn {key, value} -> {key, _replace_guids_with_channels(self, value)} end)
        end

      true ->
        payload
    end
  end

  # upstream: _connection.py:621
  def wrap_api_call(self, cb, is_internal \\ false, title \\ nil) do
    if Process.get(self[:_api_zone]) do
      cb.()
    else
      parsed_st = _attach_api_call_information(_capture_stack_trace(), is_internal, title)
      Process.put(self[:_api_zone], parsed_st)

      try do
        cb.()
      rescue
        error ->
          reraise Errors.rewrite_error(
                    error,
                    "#{parsed_st["apiName"]}: #{Exception.message(error)}"
                  ),
                  __STACKTRACE__
      after
        Process.delete(self[:_api_zone])
      end
    end
  end

  # upstream: _connection.py:640
  def wrap_api_call_sync(self, cb, is_internal \\ false, title \\ nil),
    do: wrap_api_call(self, cb, is_internal, title)

  # upstream: _connection.py:660
  def from_channel(channel), do: channel[:_object]

  # upstream: _connection.py:664
  def from_nullable_channel(channel), do: if(channel, do: channel[:_object], else: nil)

  # upstream: _connection.py:681
  def _capture_stack_trace do
    {:current_stacktrace, frames} = Process.info(self(), :current_stacktrace)
    # Skip this helper and the caller that only captures the stack.
    frames = Enum.drop(frames, 2)

    {parsed_frames, last_internal_api_name, api_name} =
      Enum.reduce(frames, {[], "", ""}, fn {module, fun, _arity, location},
                                           {parsed_frames, last_internal_api_name, api_name} ->
        filename = to_string(location[:file])
        module_name = inspect(module)

        # Py./Pyee./Asyncio runtime shims play the role of _impl_to_api_mapping: ignored.
        if String.starts_with?(module_name, ["Py", "Asyncio"]) and
             not String.starts_with?(module_name, "Playwright") do
          {parsed_frames, last_internal_api_name, api_name}
        else
          is_playwright_internal = String.starts_with?(module_name, "Playwright.")
          method_name = (module_name |> String.split(".") |> List.last()) <> "." <> to_string(fun)

          parsed_frames =
            if not is_playwright_internal,
              do:
                parsed_frames ++
                  [
                    %{
                      "file" => filename,
                      "line" => location[:line] || 0,
                      "column" => 0,
                      "function" => method_name
                    }
                  ],
              else: parsed_frames

          cond do
            is_playwright_internal ->
              {parsed_frames, method_name, api_name}

            last_internal_api_name != "" and api_name == "" ->
              {parsed_frames, "", last_internal_api_name}

            true ->
              {parsed_frames, last_internal_api_name, api_name}
          end
        end
      end)

    api_name = if api_name == "", do: last_internal_api_name, else: api_name

    %{"frames" => parsed_frames, "apiName" => api_name, "title" => nil}
  end

  # upstream: _connection.py:730
  def _attach_api_call_information(stack_trace_information, is_internal, title) do
    stack_trace_information =
      if is_internal,
        do: Map.put(stack_trace_information, "apiName", ""),
        else: stack_trace_information

    stack_trace_information = Map.put(stack_trace_information, "title", title)
    stack_trace_information
  end

  # upstream: _connection.py:741
  def _augment_params(params, timeout_calculator) do
    params = if params == nil, do: %{}, else: params
    # kwargs (keyword list) -> dict
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    {timeout_param, params} = Map.pop(params, "timeout")
    timeout = 0
    timeout = if timeout_calculator, do: timeout_calculator.(timeout_param), else: timeout
    {_filter_none(params), timeout}
  end

  # upstream: _connection.py:754
  def _filter_none(d) do
    for {k, v} <- d, v != nil, into: %{} do
      {k, if(is_map(v) and not is_struct(v), do: _filter_none(v), else: v)}
    end
  end

  # upstream: _connection.py:763
  def format_call_log(log) do
    cond do
      !log -> ""
      Enum.filter(log, &(String.trim(&1) != "")) == [] -> ""
      true -> "\nCall log:\n" <> Enum.join(log, "\n") <> "\n"
    end
  end
end
