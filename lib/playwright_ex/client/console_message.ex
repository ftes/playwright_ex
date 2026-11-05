defmodule PlaywrightEx.Client.ConsoleMessage do
  @upstream "packages/playwright-core/src/client/consoleMessage.ts"
  @moduledoc "Port of `#{@upstream}`. No mutable state: a plain struct."
  alias PlaywrightEx.Client.JSHandle

  # Elixir only: the handle is the facade's struct, `%PlaywrightEx.ConsoleMessage{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_page, :_worker, :_event]

  def new(event, page, worker) do
    # if (inspect.custom) (this as any)[inspect.custom] = () => this._inspect();  -- ported as Inspect, see below
    %PlaywrightEx.ConsoleMessage{_page: page, _worker: worker, _event: event}
  end

  def worker(this) do
    this._worker
  end

  def page(this) do
    this._page
  end

  def type(this) do
    this._event.type
  end

  def text(this) do
    this._event.text
  end

  def args(this) do
    Enum.map(this._event.args, &JSHandle.from/1)
  end

  def location(this) do
    %{url: url, lineNumber: line_number, columnNumber: column_number} = this._event.location
    %{url: url, line: line_number, column: column_number, lineNumber: line_number, columnNumber: column_number}
  end

  def timestamp(this) do
    this._event.timestamp
  end

  def _inspect(this) do
    text(this)
  end

  defimpl Inspect, for: PlaywrightEx.ConsoleMessage do
    def inspect(this, _opts), do: "#PlaywrightEx.ConsoleMessage<#{PlaywrightEx.Client.ConsoleMessage._inspect(this)}>"
  end
end
