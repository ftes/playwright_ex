defmodule Playwright.Impl.ServerErrorWithDetails do
  # upstream: ServerErrorWithDetails.java:27 (extends PlaywrightException)
  defexception [:message, :cause, :error_details, :log]

  # upstream: ServerErrorWithDetails.java:31
  def new(cause, error_details, log) do
    %__MODULE__{message: Exception.message(cause), cause: cause, error_details: error_details, log: log}
  end

  # upstream: ServerErrorWithDetails.java:44
  def error_details(this), do: this.error_details

  # upstream: ServerErrorWithDetails.java:48
  def log(this) do
    result = []
    result = if this.log != nil, do: result ++ Enum.map(this.log, &to_string/1), else: result
    result
  end
end
