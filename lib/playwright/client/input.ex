# Copyright 2017 Google Inc. All rights reserved.
# Modifications copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Client.Keyboard do
  @upstream "packages/playwright-core/src/client/input.ts"
  @moduledoc "Port of `#{@upstream}` (`class Keyboard`). No mutable state: a plain struct."
  import Playwright.Client.ChannelOwner, only: [channel_call: 4]

  alias Playwright.Client.TimeoutSettings

  # Elixir only: the handle is the facade's struct, `%Playwright.Keyboard{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_page]

  def new(page) do
    %Playwright.Keyboard{_page: page}
  end

  def down(this, key) do
    channel_call(this._page, :keyboardDown, %{key: key}, TimeoutSettings.k_no_timeout())
    nil
  end

  def up(this, key) do
    channel_call(this._page, :keyboardUp, %{key: key}, TimeoutSettings.k_no_timeout())
    nil
  end

  def insert_text(this, text) do
    channel_call(this._page, :keyboardInsertText, %{text: text}, TimeoutSettings.k_no_timeout())
    nil
  end

  def type(this, text, options \\ %{}) do
    channel_call(this._page, :keyboardType, Map.merge(%{text: text}, options || %{}), TimeoutSettings.k_no_timeout())
    nil
  end

  def press(this, key, options \\ %{}) do
    channel_call(this._page, :keyboardPress, Map.merge(%{key: key}, options || %{}), TimeoutSettings.k_no_timeout())
    nil
  end
end

defmodule Playwright.Client.Mouse do
  @upstream "packages/playwright-core/src/client/input.ts"
  @moduledoc "Port of `#{@upstream}` (`class Mouse`). No mutable state: a plain struct."
  use Playwright.Client.Decorators

  import Playwright.Client.ChannelOwner, only: [channel_call: 4]

  alias Playwright.Client.ChannelOwner
  alias Playwright.Client.TimeoutSettings

  # Elixir only: the handle is the facade's struct, `%Playwright.Mouse{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_page]

  def new(page) do
    %Playwright.Mouse{_page: page}
  end

  def _wrap_api_call(this, func, options \\ %{}) do
    ChannelOwner._wrap_api_call(this._page, func, options)
  end

  def move(this, x, y, options \\ %{}) do
    channel_call(this._page, :mouseMove, Map.merge(%{x: x, y: y}, options || %{}), TimeoutSettings.k_no_timeout())
    nil
  end

  def down(this, options \\ %{}) do
    channel_call(this._page, :mouseDown, options || %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def up(this, options \\ %{}) do
    channel_call(this._page, :mouseUp, options || %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def click(this, x, y, options \\ %{}) do
    channel_call(this._page, :mouseClick, Map.merge(%{x: x, y: y}, options || %{}), TimeoutSettings.k_no_timeout())
    nil
  end

  @api_call %{title: "Double click"}
  def dblclick(this, x, y, options \\ %{}) do
    click(this, x, y, Map.merge(options || %{}, %{clickCount: 2}))
    nil
  end

  def wheel(this, delta_x, delta_y) do
    channel_call(this._page, :mouseWheel, %{deltaX: delta_x, deltaY: delta_y}, TimeoutSettings.k_no_timeout())
    nil
  end
end

defmodule Playwright.Client.Touchscreen do
  @upstream "packages/playwright-core/src/client/input.ts"
  @moduledoc "Port of `#{@upstream}` (`class Touchscreen`). No mutable state: a plain struct."
  import Playwright.Client.ChannelOwner, only: [channel_call: 4]

  alias Playwright.Client.TimeoutSettings

  # Elixir only: the handle is the facade's struct, `%Playwright.Touchscreen{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_page]

  def new(page) do
    %Playwright.Touchscreen{_page: page}
  end

  def tap(this, x, y) do
    channel_call(this._page, :touchscreenTap, %{x: x, y: y}, TimeoutSettings.k_no_timeout())
    nil
  end
end
