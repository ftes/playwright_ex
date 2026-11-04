defmodule Playwright.Impl.LoggingSupport do
  # upstream: LoggingSupport.java:23

  # upstream: LoggingSupport.java:33
  def log_with_timestamp(message) do
    # This matches log format produced by the server.
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    IO.puts(:stderr, timestamp <> " " <> message)
  end

  # upstream: LoggingSupport.java:39
  def log_api_if_enabled(message) do
    if String.contains?(System.get_env("DEBUG", ""), "pw:api"), do: log_api(message)
  end

  # upstream: LoggingSupport.java:45
  def log_api(message) do
    # This matches log format produced by the server.
    log_with_timestamp("pw:api " <> message)
  end
end
