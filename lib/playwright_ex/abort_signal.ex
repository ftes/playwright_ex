defmodule PlaywrightEx.AbortSignal do
  @moduledoc """
  The DOM `AbortSignal` of the `signal:` options, from a `PlaywrightEx.AbortController`:

      controller = PlaywrightEx.AbortController.new()
      task = Task.async(fn -> PlaywrightEx.Locator.click(button, signal: PlaywrightEx.AbortController.signal(controller)) end)
      PlaywrightEx.AbortController.abort(controller, "user cancelled")
      {:error, %PlaywrightEx.AbortError{cause: "user cancelled"}} = Task.await(task)

  Runtime support (not ported from upstream): the part of the DOM class that Playwright uses
  (`aborted`, `reason`, `throwIfAborted`, `abort` listeners). A signal is global, as in JS: it
  belongs to no driver and works with calls on any. Its state lives in a public ETS table of the
  application, so reads are lock-free from any process, and any process aborts.

  Listeners run under the baton of the event loop (driver) that added them, as they would on its
  one JS thread: synchronously in `abort` when the aborting process holds that baton (as
  `dispatchEvent` runs them), else under it from the aborting process (which takes it) or, when
  that process holds another driver's baton, as a task of the listener's loop. A listener added
  outside any baton runs in the aborting process.

  Deviation: an aborted signal keeps one row (its reason) while the application runs; JS frees it
  with the signal. A signal that never aborts keeps none once its listeners are removed.
  """
  alias PlaywrightEx.Runtime.EventLoop

  require Logger

  defstruct [:id]

  @typedoc "An abort signal (`PlaywrightEx.AbortController.signal/1`)."
  @type t :: %__MODULE__{}

  # Rows: `{{id, :reason}, reason}` once aborted, `{{id, :listener, seq}, listener, loop}` per listener.
  @table __MODULE__

  @doc false
  # The table, owned by a process of the application (`PlaywrightEx.Application`).
  def new_table,
    do: :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true, write_concurrency: true])

  @doc false
  # `new AbortSignal()` (internal to `new AbortController()`).
  def new, do: %__MODULE__{id: make_ref()}

  @doc "`signal.aborted`: whether the controller aborted."
  @spec aborted(t()) :: boolean()
  def aborted(%__MODULE__{id: id}), do: :ets.member(@table, {id, :reason})

  @doc "`signal.reason`: the reason given to `PlaywrightEx.AbortController.abort/2`, `nil` while not aborted."
  @spec reason(t()) :: term()
  def reason(%__MODULE__{id: id}) do
    case :ets.lookup(@table, {id, :reason}) do
      [{_, reason}] -> reason
      [] -> nil
    end
  end

  @doc """
  `signal.throwIfAborted()`: raises the reason when aborted, if it is an exception, else an
  `AbortError` with the reason as its `cause` (JS throws any value).
  """
  @spec throw_if_aborted(t()) :: :ok
  def throw_if_aborted(this) do
    if aborted(this) do
      case reason(this) do
        %{__exception__: true} = e -> raise e
        reason -> raise %PlaywrightEx.AbortError{cause: reason}
      end
    end

    :ok
  end

  @doc """
  `signal.addEventListener('abort', listener, options)`: `listener` (a 0-arity function) runs
  when the signal aborts, under the baton of the caller's driver (see the moduledoc). A listener
  is added once (equal functions are the same listener); `once: true` is implied, a signal aborts
  once.
  """
  @spec add_event_listener(t(), :abort | String.t(), (-> term()), map() | keyword()) :: :ok
  def add_event_listener(%__MODULE__{id: id} = this, type, listener, _options \\ %{})
      when type in [:abort, "abort"] and is_function(listener, 0) do
    if !aborted(this) and not Enum.any?(listeners(id), &(elem(&1, 1) == listener)) do
      loop = if EventLoop.held?(), do: EventLoop.current!()
      key = {id, :listener, :erlang.unique_integer([:monotonic])}
      # A root of the loop's collector: the listener may hold objects nothing else does.
      if loop, do: :ets.insert(loop.roots, {{:abort_listener, key}, listener})
      :ets.insert(@table, {key, listener, loop})
      # An abort in another process since the check above may have missed the listener: run it
      # as that abort would have (once, see `run/1`), after the current task.
      if aborted(this), do: run_missed(key, loop)
    end

    :ok
  end

  @doc "`signal.removeEventListener('abort', listener)`."
  @spec remove_event_listener(t(), :abort | String.t(), (-> term())) :: :ok
  def remove_event_listener(%__MODULE__{id: id}, type, listener) when type in [:abort, "abort"] do
    for {key, ^listener, _loop} <- listeners(id), do: take(key)
    :ok
  end

  @doc false
  # The "signal abort" steps of the DOM spec (`AbortController.abort/2`), from any process.
  def signal_abort(%__MODULE__{id: id}, reason) do
    if :ets.insert_new(@table, {{id, :reason}, reason}) do
      for {key, _listener, loop} <- listeners(id), do: dispatch(key, loop)
    end

    :ok
  end

  defp run_missed(key, nil), do: run(key)
  defp run_missed(key, loop), do: EventLoop.post(loop, fn -> run(key) end)

  defp listeners(id), do: :ets.select(@table, [{{{id, :listener, :_}, :_, :_}, [], [:"$_"]}])

  defp dispatch(key, nil), do: run(key)

  defp dispatch(key, %EventLoop{pid: pid} = loop) do
    cond do
      EventLoop.held?() and EventLoop.current!().pid == pid -> run(key)
      # Not another driver's baton while holding one (they could wait for each other).
      EventLoop.held?() -> EventLoop.post(loop, fn -> run(key) end)
      true -> EventLoop.with_baton(loop, fn -> run(key) end)
    end
  rescue
    # The driver stopped: its listeners are gone with its calls.
    PlaywrightEx.TargetClosedError -> take(key)
  end

  # Runs a listener unless it ran or was removed already.
  defp run(key) do
    with [{_, listener, _loop}] <- take(key), do: run_listener(listener)
  end

  defp take(key) do
    with [{_, _listener, loop}] = taken <- :ets.take(@table, key) do
      if loop, do: unroot(loop, key)
      taken
    end
  end

  defp unroot(%EventLoop{roots: roots}, key) do
    :ets.delete(roots, {:abort_listener, key})
  rescue
    ArgumentError -> true
  end

  # An exception in a listener is reported, not thrown to the caller of `abort` (as in the DOM).
  defp run_listener(listener) do
    listener.()
  rescue
    e -> Logger.error("Uncaught in abort listener: " <> Exception.format(:error, e, __STACKTRACE__))
  end
end
