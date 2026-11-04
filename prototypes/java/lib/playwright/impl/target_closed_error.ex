defmodule Playwright.Impl.TargetClosedError do
  # upstream: TargetClosedError.java:21 (extends PlaywrightException)
  defexception [:message, :cause]

  # upstream: TargetClosedError.java:30
  @impl true
  def exception(message) when is_binary(message) or is_nil(message) do
    %__MODULE__{message: if(message != nil, do: message, else: "Target page, context or browser has been closed")}
  end

  def exception(opts) when is_list(opts), do: exception(opts[:message])
end
