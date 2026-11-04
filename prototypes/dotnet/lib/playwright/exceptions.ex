defmodule Playwright.PlaywrightException do
  @moduledoc "upstream: API/PlaywrightException.cs. `data` mirrors `Exception.Data` (server error details, call log)."
  defexception message: "", data: %{}, inner: nil

  def new(message \\ "", inner \\ nil), do: %__MODULE__{message: message, inner: inner}
end

defmodule Playwright.TargetClosedException do
  @moduledoc "upstream: API/TargetClosedException.cs (C# subclass of PlaywrightException; Elixir has no exception inheritance)."
  alias Playwright.Core.DriverMessages
  defexception message: DriverMessages.target_closed_exception_message(), data: %{}, inner: nil

  # upstream: API/TargetClosedException.cs:31
  def new(message \\ nil, inner \\ nil), do: %__MODULE__{message: message || DriverMessages.target_closed_exception_message(), inner: inner}
end

defmodule Playwright.TimeoutException do
  @moduledoc "Stand-in for System.TimeoutException."
  defexception message: "", data: %{}, inner: nil

  def new(message, inner \\ nil), do: %__MODULE__{message: message, inner: inner}
end
