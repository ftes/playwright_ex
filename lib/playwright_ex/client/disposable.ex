defmodule PlaywrightEx.Client.Disposable do
  @upstream "packages/playwright-core/src/client/disposable.ts"
  @moduledoc """
  Port of `#{@upstream}`: `interface Disposable`. Its implementations are
  `PlaywrightEx.Client.DisposableObject` and `PlaywrightEx.Client.DisposableStub`; `dispose/1`
  dispatches on the struct (JS virtual call).
  """

  def dispose(this), do: this.__struct__.dispose(this)

  # disposeAll  -- not ported: unused by the client (it empties the array it is given)
end

defmodule PlaywrightEx.Client.DisposableObject do
  @upstream "packages/playwright-core/src/client/disposable.ts"
  @moduledoc "Port of `#{@upstream}` (`class DisposableObject`)."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.Errors

  def from(channel) do
    channel
  end

  def new(parent, type, guid, initializer), do: ChannelOwner.new(__MODULE__, parent, type, guid, initializer)

  # [Symbol.asyncDispose]  -- not ported: await using

  def dispose(this) do
    try do
      channel_call(this, :dispose, %{}, TimeoutSettings.k_no_timeout())
    rescue
      e ->
        if Errors.is_target_closed_error(e),
          do: nil,
          else: reraise(e, __STACKTRACE__)
    end

    nil
  end
end

defmodule PlaywrightEx.Client.DisposableStub do
  @upstream "packages/playwright-core/src/client/disposable.ts"
  @moduledoc "Port of `#{@upstream}` (`class DisposableStub`): a runtime object in the loop's heap."
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Client.Errors

  defstruct [:guid, :loop, :heap]

  # `dispose` is a 0-arity function (JS `() => Promise<void>`); it may await.
  def new(dispose) do
    this = new_object(__MODULE__)
    put(this, :_dispose, dispose)
    this
  end

  # [Symbol.asyncDispose]  -- not ported: await using

  def dispose(this) do
    if !get(this, :_dispose) do
      nil
    else
      try do
        dispose = get(this, :_dispose)
        put(this, :_dispose, nil)
        dispose.()
      rescue
        e ->
          if Errors.is_target_closed_error(e),
            do: nil,
            else: reraise(e, __STACKTRACE__)
      end

      nil
    end
  end
end
