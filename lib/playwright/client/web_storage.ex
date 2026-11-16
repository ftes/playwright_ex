# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Client.WebStorage do
  @upstream "packages/playwright-core/src/client/webStorage.ts"
  @moduledoc "Port of `#{@upstream}`. No mutable state: a plain struct."
  import Playwright.Client.ChannelOwner, only: [channel_call: 4]

  alias Playwright.Client.TimeoutSettings

  # Elixir only: the handle is the facade's struct, `%Playwright.WebStorage{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_page, :_kind]

  def new(page, kind) do
    %Playwright.WebStorage{_page: page, _kind: kind}
  end

  def items(this) do
    %{items: items} = channel_call(this._page, :webStorageItems, %{kind: this._kind}, TimeoutSettings.k_no_timeout())
    items
  end

  def get_item(this, name) do
    result =
      channel_call(this._page, :webStorageGetItem, %{kind: this._kind, name: name}, TimeoutSettings.k_no_timeout())

    result[:value]
  end

  def set_item(this, name, value) do
    channel_call(
      this._page,
      :webStorageSetItem,
      %{kind: this._kind, name: name, value: value},
      TimeoutSettings.k_no_timeout()
    )

    nil
  end

  def remove_item(this, name) do
    channel_call(this._page, :webStorageRemoveItem, %{kind: this._kind, name: name}, TimeoutSettings.k_no_timeout())
    nil
  end

  def clear(this) do
    channel_call(this._page, :webStorageClear, %{kind: this._kind}, TimeoutSettings.k_no_timeout())
    nil
  end
end
