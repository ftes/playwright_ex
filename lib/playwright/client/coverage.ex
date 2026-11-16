# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Client.Coverage do
  @upstream "packages/playwright-core/src/client/coverage.ts"
  @moduledoc "Port of `#{@upstream}`. No mutable state: a plain struct (`_channel` is the page)."
  import Playwright.Client.ChannelOwner, only: [channel_call: 4]

  alias Playwright.Client.TimeoutSettings

  # Elixir only: the handle is the facade's struct, `%Playwright.Coverage{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_channel]

  def new(channel) do
    %Playwright.Coverage{_channel: channel}
  end

  def start_js_coverage(this, options \\ %{}) do
    channel_call(this._channel, :startJSCoverage, options || %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def stop_js_coverage(this) do
    channel_call(this._channel, :stopJSCoverage, %{}, TimeoutSettings.k_no_timeout()).entries
  end

  def start_css_coverage(this, options \\ %{}) do
    channel_call(this._channel, :startCSSCoverage, options || %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def stop_css_coverage(this) do
    channel_call(this._channel, :stopCSSCoverage, %{}, TimeoutSettings.k_no_timeout()).entries
  end
end
