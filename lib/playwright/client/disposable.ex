# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Client.Disposable do
  @upstream "packages/playwright-core/src/client/disposable.ts"
  @moduledoc """
  Port of `#{@upstream}`: `interface Disposable`. Its implementations are
  `Playwright.Client.DisposableObject` and `Playwright.Client.DisposableStub`; `dispose/1`
  dispatches on the handle (JS virtual call). Elixir only: both are the handle struct
  `%Playwright.Disposable{}`.
  """

  @doc false
  def __struct_fields__, do: [:guid, :conn, :table, :type, :initializer]

  # Only a channel object has a `type`.
  @doc false
  def __client__(%{type: nil}), do: Playwright.Client.DisposableStub
  def __client__(_this), do: Playwright.Client.DisposableObject

  def dispose(this), do: Playwright.Runtime.Heap.impl(this).dispose(this)

  # disposeAll  -- not ported: unused by the client (it empties the array it is given)
end

defmodule Playwright.Client.DisposableObject do
  @upstream "packages/playwright-core/src/client/disposable.ts"
  @moduledoc "Port of `#{@upstream}` (`class DisposableObject`)."
  use Playwright.Client.ChannelOwner, struct: Playwright.Disposable

  alias Playwright.Client.Errors

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

defmodule Playwright.Client.DisposableStub do
  @upstream "packages/playwright-core/src/client/disposable.ts"
  @moduledoc """
  Port of `#{@upstream}` (`class DisposableStub`). Elixir only: a runtime object owned by the
  creating process (`Playwright.Runtime.ProcessOwner`), so any process disposes it while that one
  lives; after it exits, `dispose` raises TargetClosedError (its rows are freed).
  """
  import Playwright.Runtime.Heap

  alias Playwright.Client.Errors

  # `dispose` is a 0-arity function (JS `() => Promise<void>`); it may await.
  def new(dispose) do
    this = new_object(Playwright.Disposable, Playwright.Runtime.ProcessOwner.owner())
    put(this, :_dispose, dispose)
    this
  end

  # [Symbol.asyncDispose]  -- not ported: await using

  def dispose(this) do
    # The read and the reset are one step (JS: synchronous), so concurrent disposes run it once.
    dispose =
      atomic(this, fn ->
        dispose = get(this, :_dispose)
        put(this, :_dispose, nil)
        dispose
      end)

    if !dispose do
      nil
    else
      try do
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
