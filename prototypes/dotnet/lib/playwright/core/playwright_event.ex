defmodule Playwright.PlaywrightEvent do
  @moduledoc "upstream: Core/PlaywrightEvent.cs"
  defstruct [:name]
end

defmodule Playwright.Core.PageEvent do
  @moduledoc "upstream: Core/PageEvent.cs (subset)"
  alias Playwright.PlaywrightEvent

  # upstream: Core/PageEvent.cs:33
  def crash, do: %PlaywrightEvent{name: "Crash"}
  # upstream: Core/PageEvent.cs:35
  def close, do: %PlaywrightEvent{name: "Close"}
  # upstream: Core/PageEvent.cs:39
  def download, do: %PlaywrightEvent{name: "Download"}
  # upstream: Core/PageEvent.cs:43
  def popup, do: %PlaywrightEvent{name: "Popup"}
  # upstream: Core/PageEvent.cs:47
  def frame_detached, do: %PlaywrightEvent{name: "FrameDetached"}
end

defmodule Playwright.Core.BrowserContextEvent do
  @moduledoc "upstream: Core/BrowserContextEvent.cs (subset)"
  alias Playwright.PlaywrightEvent

  # upstream: Core/BrowserContextEvent.cs:29
  def page, do: %PlaywrightEvent{name: "Page"}
  # upstream: Core/BrowserContextEvent.cs:31
  def close, do: %PlaywrightEvent{name: "Close"}
end
