# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Client.Screencast do
  @upstream "packages/playwright-core/src/client/screencast.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  `onFrame` is called with `%{data: binary, timestamp: number, viewportWidth: integer,
  viewportHeight: integer}`; the frame is acknowledged (backpressure) when it returns or, if it
  returns a promise, when that settles.
  """
  use Playwright.Client.Decorators

  import Playwright.Client.ChannelOwner, only: [channel_call: 4, _channel: 1]
  import Playwright.Runtime.Heap

  alias Playwright.Client.Artifact
  alias Playwright.Client.ChannelOwner
  alias Playwright.Client.ClientHelper
  alias Playwright.Client.DisposableStub
  alias Playwright.Client.EventEmitter
  alias Playwright.Client.TimeoutSettings
  alias Playwright.Runtime.Callers
  alias Playwright.Runtime.Promise

  # Elixir only: the handle is the facade's struct, `%Playwright.Screencast{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:guid, :conn, :table, :type, :initializer]

  # Elixir only: owned by the page.
  def new(page) do
    this = new_object(Playwright.Screencast, page)
    put(this, :_started, false)
    put(this, :_onFrame, nil)
    put(this, :_page, page)

    EventEmitter.on(_channel(get(this, :_page)), "screencastFrame", fn %{frameId: frame_id} = frame ->
      try do
        if on_frame = get(this, :_onFrame) do
          result =
            ClientHelper.call_function(on_frame, [
              %{
                data: frame.data,
                timestamp: frame.timestamp,
                viewportWidth: frame.viewportWidth,
                viewportHeight: frame.viewportHeight
              }
            ])

          if is_struct(result, Promise), do: Promise.await(result)
        end
      after
        try do
          channel_call(get(this, :_page), :screencastFrameAck, %{frameId: frame_id}, TimeoutSettings.k_no_timeout())
        rescue
          _ -> nil
        end
      end
    end)

    this
  end

  def _wrap_api_call(this, func, options \\ %{}) do
    ChannelOwner._wrap_api_call(get(this, :_page), func, options)
  end

  def start(this, options \\ %{}) do
    options = options || %{}
    if get(this, :_started), do: raise("Screencast is already started")
    put(this, :_started, true)
    # deviation: the frame listener's process calls it on the registrant's behalf (`Runtime.Callers`).
    if options[:onFrame], do: put(this, :_onFrame, Callers.bind_1(&ClientHelper.call_function(options.onFrame, [&1])))

    result =
      channel_call(
        get(this, :_page),
        :screencastStart,
        %{
          size: options[:size],
          quality: options[:quality],
          fps: options[:fps],
          sendFrames: !!options[:onFrame],
          record: !!options[:path]
        },
        TimeoutSettings.k_no_timeout()
      )

    if result[:artifact] do
      put(this, :_artifact, Artifact.from(result.artifact))
      put(this, :_savePath, options[:path])
    end

    DisposableStub.new(fn -> stop(this) end)
  end

  @api_call %{}
  def stop(this) do
    put(this, :_started, false)
    put(this, :_onFrame, nil)
    channel_call(get(this, :_page), :screencastStop, %{}, TimeoutSettings.k_no_timeout())

    if get(this, :_savePath),
      do: if(artifact = get(this, :_artifact), do: Artifact.save_as(artifact, get(this, :_savePath)))

    put(this, :_artifact, nil)
    put(this, :_savePath, nil)
    nil
  end

  def show_actions(this, options \\ nil) do
    options = options || %{}

    channel_call(
      get(this, :_page),
      :screencastShowActions,
      %{
        duration: options[:duration],
        position: options[:position],
        fontSize: options[:fontSize],
        cursor: options[:cursor],
        style: options[:style]
      },
      TimeoutSettings.k_no_timeout()
    )

    DisposableStub.new(fn ->
      channel_call(get(this, :_page), :screencastHideActions, %{}, TimeoutSettings.k_no_timeout())
    end)
  end

  def hide_actions(this) do
    channel_call(get(this, :_page), :screencastHideActions, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def show_overlay(this, html, options \\ nil) do
    options = options || %{}

    %{id: id} =
      channel_call(
        get(this, :_page),
        :screencastShowOverlay,
        %{html: html, duration: options[:duration]},
        TimeoutSettings.k_no_timeout()
      )

    DisposableStub.new(fn ->
      channel_call(get(this, :_page), :screencastRemoveOverlay, %{id: id}, TimeoutSettings.k_no_timeout())
    end)
  end

  def show_chapter(this, title, options \\ nil) do
    channel_call(
      get(this, :_page),
      :screencastChapter,
      Map.merge(%{title: title}, options || %{}),
      TimeoutSettings.k_no_timeout()
    )

    nil
  end

  def show_overlays(this) do
    channel_call(get(this, :_page), :screencastSetOverlayVisible, %{visible: true}, TimeoutSettings.k_no_timeout())
    nil
  end

  def hide_overlays(this) do
    channel_call(get(this, :_page), :screencastSetOverlayVisible, %{visible: false}, TimeoutSettings.k_no_timeout())
    nil
  end
end
