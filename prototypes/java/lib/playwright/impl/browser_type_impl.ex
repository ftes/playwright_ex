defmodule Playwright.Impl.BrowserTypeImpl do
  # upstream: BrowserTypeImpl.java:36
  use Playwright.Impl.ChannelOwner
  alias Playwright.BrowserType.LaunchOptions
  alias Playwright.Impl.{Serialization, TimeoutSettings}

  # upstream: BrowserTypeImpl.java:39
  def new(parent, type, guid, initializer), do: ChannelOwner.init(__MODULE__, parent, type, guid, initializer)

  # upstream: BrowserTypeImpl.java:44
  def launch(this, options) do
    options = options || %LaunchOptions{}
    params = Serialization.to_json_tree(options)
    result = send_message(this, "launch", params, TimeoutSettings.launch_timeout(options.timeout))
    browser = Connection.get_existing_object(this.connection, result["browser"]["guid"])
    put(browser, :browser_type, this)
    put(browser, :launch_options, options)
    browser
  end

  # upstream: BrowserTypeImpl.java:132
  def executable_path(this), do: this.initializer["executablePath"]

  # upstream: BrowserTypeImpl.java:203
  def name(this), do: this.initializer["name"]
end
