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

  Listeners run synchronously in the aborting process (as `dispatchEvent` runs them), so they
  must not block: the client's listeners only send messages. A listener added after the abort
  runs at once, in the adding process.

  Deviation: a signal's rows (its reason, its listeners) are freed when the process that created
  it exits; JS frees them with the signal.
  """
  use GenServer

  require Logger

  defstruct [:id]

  @typedoc "An abort signal (`PlaywrightEx.AbortController.signal/1`)."
  @type t :: %__MODULE__{}

  # Rows: `{{id, :reason}, reason}` once aborted, `{{id, :listener, seq}, listener}` per listener.
  @table __MODULE__

  @doc false
  # The table's owner, a process of the application (`PlaywrightEx.Application`): it frees a
  # signal's rows when its creator exits.
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc false
  # `new AbortSignal()` (internal to `new AbortController()`).
  def new do
    id = make_ref()
    GenServer.cast(__MODULE__, {:monitor, self(), id})
    %__MODULE__{id: id}
  end

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
  in the aborting process when the signal aborts (see the moduledoc). A listener is added once
  (equal functions are the same listener); `once: true` is implied, a signal aborts once.
  """
  @spec add_event_listener(t(), :abort | String.t(), (-> term()), map() | keyword()) :: :ok
  def add_event_listener(%__MODULE__{id: id} = this, type, listener, _options \\ %{})
      when type in [:abort, "abort"] and is_function(listener, 0) do
    if !aborted(this) and not Enum.any?(listeners(id), &(elem(&1, 1) == listener)) do
      key = {id, :listener, :erlang.unique_integer([:monotonic])}
      :ets.insert(@table, {key, listener})
      # An abort in another process since the check above may have missed the listener: run it
      # as that abort would have (once, see `run/1`).
      if aborted(this), do: run(key)
    end

    :ok
  end

  @doc "`signal.removeEventListener('abort', listener)`."
  @spec remove_event_listener(t(), :abort | String.t(), (-> term())) :: :ok
  def remove_event_listener(%__MODULE__{id: id}, type, listener) when type in [:abort, "abort"] do
    for {key, ^listener} <- listeners(id), do: :ets.delete(@table, key)
    :ok
  end

  @doc false
  # The "signal abort" steps of the DOM spec (`AbortController.abort/2`), from any process.
  def signal_abort(%__MODULE__{id: id}, reason) do
    if :ets.insert_new(@table, {{id, :reason}, reason}) do
      for {key, _listener} <- listeners(id), do: run(key)
    end

    :ok
  end

  defp listeners(id), do: :ets.select(@table, [{{{id, :listener, :_}, :_}, [], [:"$_"]}])

  # Runs a listener unless it ran or was removed already.
  defp run(key) do
    with [{_, listener}] <- :ets.take(@table, key), do: run_listener(listener)
  end

  # An exception in a listener is reported, not thrown to the caller of `abort` (as in the DOM).
  defp run_listener(listener) do
    listener.()
  rescue
    e -> Logger.error("Uncaught in abort listener: " <> Exception.format(:error, e, __STACKTRACE__))
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true, write_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:monitor, pid, id}, signals) do
    signals =
      case signals do
        %{^pid => {mon, ids}} -> Map.put(signals, pid, {mon, [id | ids]})
        _ -> Map.put(signals, pid, {Process.monitor(pid), [id]})
      end

    {:noreply, signals}
  end

  @impl true
  def handle_info({:DOWN, _mon, :process, pid, _reason}, signals) do
    {{_mon, ids}, signals} = Map.pop(signals, pid)

    for id <- ids do
      :ets.delete(@table, {id, :reason})
      :ets.select_delete(@table, [{{{id, :listener, :_}, :_}, [], [true]}])
    end

    {:noreply, signals}
  end
end
