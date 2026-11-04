defmodule PlaywrightEx.Isomorphic.ManualPromise do
  @upstream "packages/isomorphic/manualPromise.ts"
  @moduledoc """
  Port of `#{@upstream}`: `LongStandingScope` is `PlaywrightEx.Isomorphic.LongStandingScope`.
  """

  # ManualPromise: constructor, isDone, resolve, reject  -- ported as PlaywrightEx.Runtime.Promise (new/1, resolve/2, reject/2)
  # signalToPromise  -- not ported: AbortSignal

  # A plain `Error` copy: `RuntimeError`, as the client raises for `new Error()` (stack rewriting not ported).
  def clone_error(error, _frames) do
    %RuntimeError{message: Exception.message(error)}
  end
end

defmodule PlaywrightEx.Isomorphic.LongStandingScope do
  @upstream "packages/isomorphic/manualPromise.ts"
  @moduledoc "Port of `LongStandingScope` in `#{@upstream}`."
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Isomorphic.ManualPromise
  alias PlaywrightEx.Runtime.Promise

  defstruct [:guid, :loop, :heap]

  def new do
    this = new_object(__MODULE__)
    put(this, :_isClosed, false)
    this
  end

  def reject(this, error) do
    put(this, :_isClosed, true)
    put(this, :_terminateError, error)
    for {_, p} <- map_values(this, :_terminatePromises), do: Promise.resolve(p, error)
  end

  def close(this, error) do
    put(this, :_isClosed, true)
    put(this, :_closeError, error)

    for {frames, p} <- map_values(this, :_terminatePromises),
        do: Promise.resolve(p, ManualPromise.clone_error(error, frames))
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
    terminate_promise = Promise.new()
    # const frames = (new Error().stack || '').split('\n');  -- not ported: stack rewriting
    frames = []
    if get(this, :_terminateError), do: Promise.resolve(terminate_promise, get(this, :_terminateError))

    if get(this, :_closeError),
      do: Promise.resolve(terminate_promise, ManualPromise.clone_error(get(this, :_closeError), frames))

    # Map<ManualPromise, frames>: keyed by a ref, the value keeps both.
    key = make_ref()
    map_set(this, :_terminatePromises, key, {frames, terminate_promise})

    try do
      Promise.await(
        Promise.race([
          Promise.then_(terminate_promise, fn e -> if safe, do: default_value, else: raise(e) end) | promises
        ])
      )
    after
      map_delete(this, :_terminatePromises, key)
    end
  end
end
