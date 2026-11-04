# `Events.Page.Close` becomes `Events.Page.close()`.
defmodule PlaywrightEx.Client.Events do
  @upstream "packages/playwright-core/src/client/events.ts"
  @moduledoc "Port of `#{@upstream}`."
  defmodule Browser do
    @moduledoc false
    def context, do: "context"
    def disconnected, do: "disconnected"
  end

  defmodule Debugger do
    @moduledoc false
    def paused_state_changed, do: "pausedstatechanged"
    def api_calls_updated, do: "apicallsupdated"
  end

  defmodule BrowserContext do
    @moduledoc false
    def console, do: "console"
    def close, do: "close"
    def dialog, do: "dialog"
    def dialog_closed, do: "dialogclosed"
    def download, do: "download"
    def frame_attached, do: "frameattached"
    def frame_detached, do: "framedetached"
    def frame_navigated, do: "framenavigated"
    def page, do: "page"
    def page_close, do: "pageclose"
    def page_load, do: "pageload"
    def web_error, do: "weberror"
    def service_worker, do: "serviceworker"
    def request, do: "request"
    def response, do: "response"
    def request_failed, do: "requestfailed"
    def request_finished, do: "requestfinished"
  end

  defmodule Page do
    @moduledoc false
    def close, do: "close"
    def crash, do: "crash"
    def console, do: "console"
    def dialog, do: "dialog"
    def dialog_closed, do: "dialogclosed"
    def download, do: "download"
    def file_chooser, do: "filechooser"
    def dom_content_loaded, do: "domcontentloaded"
    def page_error, do: "pageerror"
    def request, do: "request"
    def response, do: "response"
    def request_failed, do: "requestfailed"
    def request_finished, do: "requestfinished"
    def frame_attached, do: "frameattached"
    def frame_detached, do: "framedetached"
    def frame_navigated, do: "framenavigated"
    def load, do: "load"
    def popup, do: "popup"
    def web_socket, do: "websocket"
    def worker, do: "worker"
  end

  defmodule WebSocket do
    @moduledoc false
    def close, do: "close"
    def error, do: "socketerror"
    def frame_received, do: "framereceived"
    def frame_sent, do: "framesent"
  end

  defmodule Worker do
    @moduledoc false
    def close, do: "close"
    def console, do: "console"
  end
end
