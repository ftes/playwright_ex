defmodule PlaywrightEx.Isomorphic.ManualPromise do
  @upstream "packages/isomorphic/manualPromise.ts"
  @moduledoc """
  Port of `#{@upstream}`: `LongStandingScope` is `PlaywrightEx.Isomorphic.LongStandingScope`.
  """

  alias PlaywrightEx.AbortSignal
  alias PlaywrightEx.Runtime.Promise

  # ManualPromise: constructor, isDone, resolve, reject  -- ported as PlaywrightEx.Runtime.Promise (new/1, resolve/2, reject/2)

  def signal_to_promise(signal) do
    if AbortSignal.aborted(signal) do
      {Promise.resolved(nil), fn -> nil end}
    else
      # `let dispose` assigned inside the executor: the listener is created first.
      promise = Promise.new()
      on_abort = fn -> Promise.resolve(promise, nil) end
      AbortSignal.add_event_listener_after_check(signal, on_abort)
      dispose = fn -> AbortSignal.remove_event_listener(signal, "abort", on_abort) end
      {promise, dispose}
    end
  end

  # A plain `Error` copy: `RuntimeError`, as the client raises for `new Error()` (stack rewriting not ported).
  def clone_error(error, _frames) do
    %RuntimeError{message: Exception.message(error)}
  end
end

defmodule PlaywrightEx.Isomorphic.LongStandingScope do
  @upstream "packages/isomorphic/manualPromise.ts"
  @moduledoc """
  Port of `LongStandingScope` in `#{@upstream}`. Elixir only: `owner` (the page, worker, ...)
  owns its rows; its terminate promises are latches, so any process races the scope.
  """
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Isomorphic.ManualPromise
  alias PlaywrightEx.Runtime.Promise

  defstruct [:guid, :conn, :table]

  def new(owner) do
    this = new_object(__MODULE__, owner)
    put(this, :_isClosed, false)
    this
  end

  def reject(this, error) do
    put(this, :_isClosed, true)
    put(this, :_terminateError, error)
    for {_, p} <- map_values(this, :_terminatePromises), do: Promise.resolve(p, error)
    nil
  end

  def close(this, error) do
    put(this, :_isClosed, true)
    put(this, :_closeError, error)

    for {frames, p} <- map_values(this, :_terminatePromises),
        do: Promise.resolve(p, ManualPromise.clone_error(error, frames))

    nil
  end

  def is_closed(this) do
    get(this, :_isClosed)
  end

  def race_multiple(scopes, promise) do
    Promise.await(Promise.race(Enum.map(scopes, fn s -> Promise.async(fn -> race(s, promise) end) end)))
  end

  def race(this, promise) do
    _race(this, if(is_list(promise), do: promise, else: [promise]), false)
  end

  def safe_race(this, promise, default_value \\ nil) do
    _race(this, [promise], true, default_value)
  end

  defp _race(this, promises, safe, default_value \\ nil) do
    # A latch on the scope: settled by whichever process closes it.
    terminate_promise = Promise.new(this)
    # const frames = (new Error().stack || '').split('\n');  -- not ported: stack rewriting
    frames = []
    # Map<ManualPromise, frames>: keyed by a ref, the value keeps both.
    key = make_ref()

    # Elixir only: atomic, as the synchronous section in JS (a close or reject in between would
    # miss the new entry).
    atomic(this, fn ->
      if get(this, :_terminateError), do: Promise.resolve(terminate_promise, get(this, :_terminateError))

      if get(this, :_closeError),
        do: Promise.resolve(terminate_promise, ManualPromise.clone_error(get(this, :_closeError), frames))

      map_set(this, :_terminatePromises, key, {frames, terminate_promise})
    end)

    try do
      Promise.await(
        Promise.race([
          Promise.then_(terminate_promise, fn e -> if safe, do: default_value, else: raise(e) end) | promises
        ])
      )
    after
      # Elixir only: the latch's row goes too.
      try do
        map_delete(this, :_terminatePromises, key)
        Promise.free(terminate_promise)
      rescue
        PlaywrightEx.TargetClosedError -> :ok
      end
    end
  end
end
