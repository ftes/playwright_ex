defmodule Playwright.Core.BrowserType do
  @moduledoc "upstream: Core/BrowserType.cs"
  use Playwright.Transport.ChannelOwner, [:initializer]

  alias Playwright.Core.Browser
  alias Playwright.Core.TimeoutSettings
  alias Playwright.Transport.ChannelOwner

  # upstream: Core/BrowserType.cs:41
  def new(parent, guid, initializer) do
    ChannelOwner.new(__MODULE__, parent, guid, initializer: initializer)
  end

  # upstream: Core/BrowserType.cs:46
  def playwright(this), do: ChannelOwner.get(this, :playwright)

  # upstream: Core/BrowserType.cs:48
  def executable_path(this), do: this.initializer.executable_path

  # upstream: Core/BrowserType.cs:50
  def name(this), do: this.initializer.name

  # upstream: Core/BrowserType.cs:53
  def launch(this, options \\ nil) do
    options = options || []
    browser = ChannelOwner.send_message_to_server(
      this,
      "launch",
      %{
        "channel" => options[:channel],
        "executablePath" => options[:executable_path],
        "args" => options[:args],
        "ignoreAllDefaultArgs" => options[:ignore_all_default_args],
        "ignoreDefaultArgs" => options[:ignore_default_args],
        "handleSIGHUP" => options[:handle_sighup],
        "handleSIGINT" => options[:handle_sigint],
        "handleSIGTERM" => options[:handle_sigterm],
        "headless" => options[:headless],
        "env" => options[:env] && Enum.map(options[:env], fn {k, v} -> %{"name" => k, "value" => v} end),
        "proxy" => options[:proxy],
        "downloadsPath" => options[:downloads_path],
        "tracesDir" => options[:traces_dir],
        "artifactsDir" => options[:artifacts_dir],
        "firefoxUserPrefs" => options[:firefox_user_prefs],
        "chromiumSandbox" => options[:chromium_sandbox],
        "slowMo" => options[:slow_mo],
      },
      timeout: TimeoutSettings.launch_timeout(options[:timeout]), as: Browser)
    Browser.connect_to_browser_type(browser, this, options[:traces_dir])
    browser
  end
end
