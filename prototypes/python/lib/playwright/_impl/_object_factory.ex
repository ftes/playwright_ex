# upstream: playwright/_impl/_object_factory.py
alias Playwright.Impl.Connection.ChannelOwner

alias Playwright.Impl.{
  Artifact,
  Browser,
  BrowserContext,
  BrowserType,
  Frame,
  LocalUtils,
  Page,
  Stream
}

alias Playwright.Impl.Playwright, as: PlaywrightImpl

defmodule Playwright.Impl.ObjectFactory.DummyObject do
  use ChannelOwner

  # upstream: _object_factory.py:46
  def init(parent, type, guid, initializer),
    do: ChannelOwner.init(Py.new(__MODULE__), parent, type, guid, initializer)
end

defmodule Playwright.Impl.ObjectFactory do
  alias Playwright.Impl.ObjectFactory.DummyObject

  # upstream: _object_factory.py:52
  def create_remote_object(parent, type, guid, initializer) do
    case type do
      "Artifact" ->
        Artifact.init(parent, type, guid, initializer)

      "Browser" ->
        Browser.init(parent, type, guid, initializer)

      "BrowserType" ->
        BrowserType.init(parent, type, guid, initializer)

      "BrowserContext" ->
        BrowserContext.init(parent, type, guid, initializer)

      "Frame" ->
        Frame.init(parent, type, guid, initializer)

      "LocalUtils" ->
        local_utils = LocalUtils.init(parent, type, guid, initializer)

        if !local_utils[:_connection][:_local_utils],
          do: Py.set(local_utils[:_connection], :_local_utils, local_utils)

        local_utils

      "Page" ->
        Page.init(parent, type, guid, initializer)

      "Playwright" ->
        PlaywrightImpl.init(parent, type, guid, initializer)

      "Stream" ->
        Stream.init(parent, type, guid, initializer)

      # (APIRequestContext, BindingCall, CDPSession, Debugger, Dialog, Disposable,
      #  ElementHandle, JSHandle, Request, Response, Route, Tracing, WebSocket,
      #  WebSocketRoute, Worker, WritableStream: not in prototype subset)
      _ ->
        DummyObject.init(parent, type, guid, initializer)
    end
  end
end
