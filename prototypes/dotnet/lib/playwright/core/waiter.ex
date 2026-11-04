defmodule Playwright.Core.Waiter do
  @moduledoc """
  upstream: Core/Waiter.cs

  OTP mapping of `Task`/`TaskCompletionSource`/`Task.WhenAny`:
  * A Waiter is a caller-local object (`using var waiter = new Waiter(...)`). Its mutable fields
    (`_logs`, `_failures`, `_dispose`, `_error`) live in the *owning process's* dictionary, so
    predicates can call `log/2` like the C# lambdas do.
  * An event "task" is a Registry subscription of the calling process: the event payload arrives as
    `{:playwright_event, ref, payload}` and simply waits in the mailbox until awaited.
  * `RejectOnTimeout` -> `Process.send_after(self(), {:waiter_timeout, ref}, ms)`.
  * `Task.WhenAny(task, failures...)` -> one selective `receive` over all of those refs.
  * C# async methods that return a hot Task are ported as: do the eager part, return a thunk;
    `await t` is `t.()`.
  """
  alias Playwright.PlaywrightException
  alias Playwright.TimeoutException
  alias Playwright.Transport.ChannelOwner
  alias Playwright.Transport.Connection

  defstruct [:id]

  # upstream: Core/Waiter.cs:49
  def new(channel_owner, event) do
    this = %__MODULE__{id: make_ref()}
    wait_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    put_state(this, %{channel_owner: channel_owner, wait_id: wait_id, logs: [], failures: %{}, dispose: [], immediate_error: nil, disposed: false, error: nil})

    before_args = %{
      "event" => event,
      "waitId" => wait_id,
      "phase" => "before"
    }
    # _failures.Add(Task.Delay(-1, _manualCts.Token)): not needed, an exception in the action propagates directly.
    # An outer WrapApiCallAsync may have set its own title (e.g. "Wait for navigation");
    # fall back to ours only when there is no outer zone.
    ignore_exception(fn ->
      ChannelOwner.wrap_api_call(
        channel_owner,
        fn -> Connection.send_message_to_server(channel_owner.connection, channel_owner, "__waitInfo__", before_args) end,
        false,
        "Wait for event \"#{event}\""
      )
    end)
    this
  end

  # upstream: Core/Waiter.cs:68
  def dispose(this) do
    state = state(this)

    if !state.disposed do
      put_state(this, %{state | disposed: true})
      for dispose <- state.dispose do
        dispose.()
      end

      after_args = %{
        "waitId" => state.wait_id,
        "phase" => "after"
      }
      after_args = if state.error not in [nil, ""], do: Map.put(after_args, "error", state.error), else: after_args

      ignore_exception(fn ->
        ChannelOwner.wrap_api_call(state.channel_owner, fn -> Connection.send_message_to_server(state.channel_owner.connection, state.channel_owner, "__waitInfo__", after_args) end, true)
      end)
    end
  end

  # upstream: Core/Waiter.cs:97
  def log(this, log) do
    state = state(this)
    put_state(this, %{state | logs: state.logs ++ [log]})

    log_args = %{
      "waitId" => state.wait_id,
      "phase" => "log",
      "message" => log
    }
    ignore_exception(fn ->
      ChannelOwner.wrap_api_call(state.channel_owner, fn -> Connection.send_message_to_server(state.channel_owner.connection, state.channel_owner, "__waitInfo__", log_args) end, true)
    end)
  end

  # upstream: Core/Waiter.cs:110
  def reject_immediately(this, exception), do: put_state(this, %{state(this) | immediate_error: exception})

  # upstream: Core/Waiter.cs:115 + :124 (exception or exception factory)
  def reject_on_event(this, event_source, e, navigation_exception, predicate \\ nil) do
    navigation_exception = if is_function(navigation_exception), do: navigation_exception, else: fn -> navigation_exception end

    if event_source != nil do
      {task, dispose} = get_wait_for_event_task(this, event_source, e, predicate)
      reject_on(this, {:reject, task, navigation_exception}, dispose)
    end
  end

  # upstream: Core/Waiter.cs:141
  def reject_on_timeout(this, timeout, message) do
    if timeout != nil do
      ref = make_ref()
      timer = Process.send_after(self(), {:waiter_timeout, ref}, timeout)
      reject_on(this, {:timeout, ref, message}, fn -> Process.cancel_timer(timer) end)
    end
  end

  # upstream: Core/Waiter.cs:154 (returns a thunk: C# returns a hot Task<T>)
  def wait_for_event_async(this, event_source, e, predicate \\ nil) do
    {task, dispose} = get_wait_for_event_task(this, event_source, e, predicate)
    fn -> wait_for_promise_async(this, task, dispose) end
  end

  # upstream: Core/Waiter.cs:166
  def get_wait_for_event_task(_this, event_source, e, predicate) do
    ref = ChannelOwner.subscribe(event_source, e)
    {{:event, ref, predicate || fn _ -> true end}, fn -> ChannelOwner.unsubscribe(event_source, e, ref) end}
  end

  # upstream: Core/Waiter.cs:196 (task: {:event, ref, pred} | %Task{} | {:exception, e})
  def wait_for_promise_async(this, task, dispose \\ nil) do
    try do
      if state(this).immediate_error != nil do
        raise state(this).immediate_error
      end

      first_task = when_any(task, state(this).failures)
      if dispose, do: dispose.()

      case first_task do
        {:ok, value} -> value
        {:error, exception} -> raise exception
      end
    rescue
      ex in TimeoutException ->
        if dispose, do: dispose.()
        put_state(this, %{state(this) | error: Exception.message(ex)})
        dispose(this)
        reraise TimeoutException.new(ex.message <> format_log_recording(state(this).logs), ex), __STACKTRACE__

      ex ->
        if dispose, do: dispose.()
        put_state(this, %{state(this) | error: Exception.message(ex)})
        dispose(this)
        reraise PlaywrightException.new(Exception.message(ex) <> format_log_recording(state(this).logs), ex), __STACKTRACE__
    end
  end

  # upstream: Core/Waiter.cs:232 — the event task is already buffering into our mailbox, so running the
  # action here and awaiting the task afterwards is equivalent to Task.WhenAll(waitForEventTask, actionTask).
  def cancel_wait_on_exception_async(_this, _wait_for_event_task, action) do
    action.()
  end

  # upstream: Core/Waiter.cs:253
  defp format_log_recording(logs) do
    if logs == [] do
      ""
    else
      header = " logs "
      header_length = 60
      left_length = div(header_length - String.length(header), 2)
      right_length = header_length - String.length(header) - left_length
      log = Enum.join(logs, "\n")

      "\n#{String.duplicate("=", left_length)}#{header}#{String.duplicate("=", right_length)}\n#{log}\n#{String.duplicate("=", header_length)}"
    end
  end

  # upstream: Core/Waiter.cs:269
  defp reject_on(this, task, dispose) do
    state = state(this)
    key = elem(task, 1) |> task_ref()
    put_state(this, %{state | failures: Map.put(state.failures, key, task), dispose: state.dispose ++ [dispose]})
  end

  # ---- Elixir-only: Task.WhenAny as a selective receive ----------------------------------------

  defp task_ref({:event, ref, _}), do: ref
  defp task_ref(ref) when is_reference(ref), do: ref

  defp when_any({:exception, e}, _failures), do: {:error, e}

  defp when_any(task, failures) do
    {task_ref, matches?} =
      case task do
        {:event, ref, predicate} -> {ref, predicate}
        %Task{ref: ref} -> {ref, nil}
      end

    receive do
      {:playwright_event, ^task_ref, payload} ->
        case safe(fn -> matches?.(payload) end) do
          {:ok, true} -> {:ok, payload}
          {:ok, _} -> when_any(task, failures)
          error -> error
        end

      {^task_ref, result} ->
        Process.demonitor(task_ref, [:flush])
        result

      {:playwright_event, ref, payload} when is_map_key(failures, ref) ->
        {:reject, {:event, _, predicate}, exception} = failures[ref]

        case safe(fn -> predicate.(payload) end) do
          {:ok, true} -> {:error, exception.()}
          {:ok, _} -> when_any(task, failures)
          error -> error
        end

      {:waiter_timeout, ref} when is_map_key(failures, ref) ->
        {:timeout, _, message} = failures[ref]
        {:error, TimeoutException.new(message)}
    end
  end

  @doc "C# `Task.Run(...)`/async server call used as a promise: an OTP Task replying `{:ok, v} | {:error, e}`."
  def async(fun), do: Task.async(fn -> safe(fun) end)

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, e}
  end

  defp ignore_exception(fun) do
    fun.()
  rescue
    _ -> :ok
  end

  defp state(this), do: Process.get({__MODULE__, this.id})
  defp put_state(this, state), do: Process.put({__MODULE__, this.id}, state)
end
