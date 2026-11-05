defmodule PlaywrightEx.AbortSignal do
  @moduledoc """
  The DOM `AbortSignal` of the `signal:` options, from a `PlaywrightEx.AbortController`:

      controller = PlaywrightEx.AbortController.new()
      task = Task.async(fn -> PlaywrightEx.Locator.click(button, signal: PlaywrightEx.AbortController.signal(controller)) end)
      PlaywrightEx.AbortController.abort(controller, "user cancelled")
      {:error, %PlaywrightEx.Client.Errors.AbortError{cause: "user cancelled"}} = Task.await(task)

  Runtime support (not ported from upstream): the part of the DOM class that Playwright uses
  (`aborted`, `reason`, `throwIfAborted`, `abort` listeners). The signal is an object of the
  event loop's heap, like a promise: reads are lock-free from any process, `abort` takes the
  baton, so that it is atomic with the calls checking the signal and listening to it, as on
  the one JS thread. Listeners run synchronously in `abort`, as `dispatchEvent` runs them.
  """
  import PlaywrightEx.Runtime.Heap

  require Logger

  defstruct [:guid, :loop, :heap]

  @typedoc "An abort signal (`PlaywrightEx.AbortController.signal/1`)."
  @type t :: %__MODULE__{}

  @doc false
  # `new AbortSignal()` (internal to `new AbortController()`), under the baton.
  def new do
    this = new_object(__MODULE__)
    put(this, :aborted, false)
    put(this, :reason, nil)
    put(this, :listeners, [])
    this
  end

  @doc "`signal.aborted`: whether the controller aborted."
  @spec aborted(t()) :: boolean()
  def aborted(this), do: get(this, :aborted) == true

  @doc "`signal.reason`: the reason given to `PlaywrightEx.AbortController.abort/2`, `nil` while not aborted."
  @spec reason(t()) :: term()
  def reason(this), do: get(this, :reason)

  @doc """
  `signal.throwIfAborted()`: raises the reason when aborted, if it is an exception, else an
  `AbortError` with the reason as its `cause` (JS throws any value).
  """
  @spec throw_if_aborted(t()) :: :ok
  def throw_if_aborted(this) do
    if aborted(this) do
      case reason(this) do
        %{__exception__: true} = e -> raise e
        reason -> raise %PlaywrightEx.Client.Errors.AbortError{cause: reason}
      end
    end

    :ok
  end

  @doc """
  `signal.addEventListener('abort', listener, options)`: `listener` (a 0-arity function) runs
  when the signal aborts, in the process calling `PlaywrightEx.AbortController.abort/2`. A
  listener is added once (equal functions are the same listener); `once: true` is implied, a
  signal aborts once.
  """
  @spec add_event_listener(t(), :abort | String.t(), (-> term()), map() | keyword()) :: :ok
  def add_event_listener(this, type, listener, _options \\ %{})
      when type in [:abort, "abort"] and is_function(listener, 0) do
    if !aborted(this), do: update(this, :listeners, &if(listener in &1, do: &1, else: &1 ++ [listener]))
    :ok
  end

  @doc "`signal.removeEventListener('abort', listener)`."
  @spec remove_event_listener(t(), :abort | String.t(), (-> term())) :: :ok
  def remove_event_listener(this, type, listener) when type in [:abort, "abort"] do
    update(this, :listeners, &List.delete(&1 || [], listener))
    :ok
  end

  @doc false
  # The "signal abort" steps of the DOM spec (`AbortController.abort/2`), under the baton.
  def signal_abort(this, reason) do
    if !aborted(this) do
      put(this, :aborted, true)
      put(this, :reason, reason)
      listeners = get(this, :listeners)
      put(this, :listeners, [])
      Enum.each(listeners, &run_listener/1)
    end

    :ok
  end

  # An exception in a listener is reported, not thrown to the caller of `abort` (as in the DOM).
  defp run_listener(listener) do
    listener.()
  rescue
    e -> Logger.error("Uncaught in abort listener: " <> Exception.format(:error, e, __STACKTRACE__))
  end
end
