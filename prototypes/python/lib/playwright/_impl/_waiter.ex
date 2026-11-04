# upstream: playwright/_impl/_waiter.py
defmodule Playwright.Impl.Waiter do
  use Py
  alias Asyncio.Future
  alias Playwright.Impl.Connection.Channel
  alias Playwright.Impl.Errors
  alias Playwright.Impl.Errors.{Error, TimeoutError}

  # upstream: _waiter.py:29
  def init(channel_owner, event) do
    self = Py.new(__MODULE__)
    Py.set(self, :_result, Future.new())
    Py.set(self, :_wait_id, Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
    Py.set(self, :_loop, channel_owner[:_loop])
    Py.set(self, :_pending_tasks, [])
    Py.set(self, :_channel, channel_owner[:_channel])
    Py.set(self, :_registered_listeners, [])
    Py.set(self, :_logs, [])
    _wait_for_event_info_before(self, self[:_wait_id], event)
    self
  end

  # upstream: _waiter.py:39
  def _wait_for_event_info_before(self, wait_id, event) do
    _send_wait_for_event_info(
      self,
      %{"waitId" => wait_id, "phase" => "before", "event" => event},
      false,
      ~s(Wait for event "#{event}")
    )
  end

  # upstream: _waiter.py:49
  def _wait_for_event_info_after(self, wait_id, error \\ nil) do
    _send_wait_for_event_info(
      self,
      Map.merge(
        %{"waitId" => wait_id, "phase" => "after"},
        if(error, do: %{"error" => Exception.message(error)}, else: %{})
      ),
      true
    )
  end

  # upstream: _waiter.py:59
  def _send_wait_for_event_info(self, params, is_internal \\ false, title \\ nil) do
    # Wait info is fire-and-forget telemetry and must not affect the waiter.
    try do
      Channel.send_no_reply(self[:_channel], "__waitInfo__", nil, params, is_internal, title)
    rescue
      e -> if not Errors.is_error(e), do: reraise(e, __STACKTRACE__)
    end
  end

  # upstream: _waiter.py:74
  def reject_on_event(self, emitter, event, error, predicate \\ nil) do
    on_match = fn -> _reject(self, if(is_function(error), do: error.(), else: error)) end

    listener = fn event_data -> _evaluate_predicate(self, predicate, event_data, on_match) end

    emitter.__struct__.on(emitter, event, listener)
    Py.append(self, :_registered_listeners, {emitter, event, listener})
  end

  # upstream: _waiter.py:90
  def reject_on_timeout(self, timeout, message) do
    if timeout != 0 do
      reject = fn ->
        Asyncio.sleep(timeout / 1000)
        _reject(self, TimeoutError.new(message))
      end

      Py.append(self, :_pending_tasks, Asyncio.create_task(reject))
    end
  end

  # upstream: _waiter.py:100
  def _cleanup(self) do
    for task <- self[:_pending_tasks],
        do: if(not Asyncio.Task.done(task) and task.pid != self(), do: Asyncio.Task.cancel(task))

    for {emitter, event, listener} <- self[:_registered_listeners],
        do: emitter.__struct__.remove_listener(emitter, event, listener)
  end

  # upstream: _waiter.py:107
  def _fulfill(self, result) do
    _cleanup(self)
    if not Future.done(self[:_result]), do: Future.set_result(self[:_result], result)
    _wait_for_event_info_after(self, self[:_wait_id])
  end

  # upstream: _waiter.py:113
  def _reject(self, exception) do
    _cleanup(self)

    exception =
      if exception do
        base_class = if is_struct(exception, TimeoutError), do: TimeoutError, else: Error
        base_class.new(Exception.message(exception) <> format_log_recording(self[:_logs]))
      end

    if not Future.done(self[:_result]), do: Future.set_exception(self[:_result], exception)
    _wait_for_event_info_after(self, self[:_wait_id], exception)
  end

  # upstream: _waiter.py:122
  def wait_for_event(self, emitter, event, predicate \\ nil) do
    listener = fn event_data ->
      _evaluate_predicate(self, predicate, event_data, fn -> _fulfill(self, event_data) end)
    end

    emitter.__struct__.on(emitter, event, listener)
    Py.append(self, :_registered_listeners, {emitter, event, listener})
  end

  # upstream: _waiter.py:136
  def _evaluate_predicate(self, predicate, event_data, on_match) do
    if predicate == nil do
      on_match.()
    else
      result =
        try do
          {:ok, predicate.(event_data)}
        rescue
          e -> {:error, e}
        end

      case result do
        {:error, e} -> _reject(self, e)
        # (inspect.iscoroutine(result) branch: predicates are plain functions on the BEAM)
        {:ok, result} -> if Py.bool(result), do: on_match.()
      end
    end
  end

  # upstream: _waiter.py:166
  def result(self), do: self[:_result]

  # upstream: _waiter.py:169
  def log(self, message) do
    Py.append(self, :_logs, message)

    _send_wait_for_event_info(
      self,
      %{"waitId" => self[:_wait_id], "phase" => "log", "message" => message},
      true
    )
  end

  # upstream: _waiter.py:189
  def format_log_recording(log) do
    if log == [] or log == nil do
      ""
    else
      header = " logs "
      header_length = 60
      left_length = div(header_length - String.length(header), 2)
      right_length = header_length - String.length(header) - left_length
      new_line = "\n"

      "#{new_line}#{String.duplicate("=", left_length)}#{header}#{String.duplicate("=", right_length)}#{new_line}#{Enum.join(log, new_line)}#{new_line}#{String.duplicate("=", header_length)}"
    end
  end
end
