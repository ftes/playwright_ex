# upstream: packages/playwright-core/src/client/consoleMessage.ts
# ConsoleMessage is never mutated after construction -> plain immutable struct (no heap).
defmodule PlaywrightJS.Client.ConsoleMessage do
  use PlaywrightJS.Client.Api

  defstruct [:_page, :_worker, :_event]

  # upstream: consoleMessage.ts:32
  def new(event, page, worker) do
    # if (inspect.custom) ...  -- n/a
    %__MODULE__{_page: page, _worker: worker, _event: event}
  end

  # upstream: consoleMessage.ts:40
  def worker(this) do
    this._worker
  end

  # upstream: consoleMessage.ts:44
  def page(this) do
    this._page
  end

  # upstream: consoleMessage.ts:48
  def type(this) do
    this._event.type
  end

  # upstream: consoleMessage.ts:52
  def text(this) do
    this._event.text
  end

  # upstream: consoleMessage.ts:56
  def args(this) do
    this._event.args
  end

  # upstream: consoleMessage.ts:60
  def location(this) do
    %{url: url, lineNumber: line_number, columnNumber: column_number} = this._event.location
    %{url: url, line: line_number, column: column_number, lineNumber: line_number, columnNumber: column_number}
  end

  # upstream: consoleMessage.ts:65
  def timestamp(this) do
    this._event.timestamp
  end
end
