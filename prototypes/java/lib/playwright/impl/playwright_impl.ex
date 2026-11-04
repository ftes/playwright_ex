defmodule Playwright.Impl.PlaywrightImpl do
  # upstream: PlaywrightImpl.java:32
  use Playwright.Impl.ChannelOwner
  alias Playwright.Impl.{Driver, SelectorsImpl}
  alias Playwright.PlaywrightException

  # upstream: PlaywrightImpl.java:35
  def create(options), do: create_impl(options, false)

  # upstream: PlaywrightImpl.java:39
  def create_impl(options, _force_new_driver_instance_for_tests) do
    env = %{}
    env = if options != nil and options.env != nil, do: options.env, else: env
    driver = Driver.ensure_driver_installed(env, true)

    try do
      pb = Driver.create_process_builder(driver)
      command = pb ++ ["run-driver"]
      connection = Connection.new(command, env)
      result = Connection.initialize_playwright(connection)
      put(result, :driver_process, connection.pid)
      result
    rescue
      e in ErlangError -> reraise PlaywrightException, [message: "Failed to launch driver", cause: e], __STACKTRACE__
    end
  end

  # upstream: PlaywrightImpl.java:67
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.init(__MODULE__, parent, type, guid, initializer)
    chromium = Connection.get_existing_object(parent.connection, initializer["chromium"]["guid"])
    firefox = Connection.get_existing_object(parent.connection, initializer["firefox"]["guid"])
    webkit = Connection.get_existing_object(parent.connection, initializer["webkit"]["guid"])
    put(this, :chromium, chromium)
    put(this, :firefox, firefox)
    put(this, :webkit, webkit)

    put(chromium, :playwright, this)
    put(firefox, :playwright, this)
    put(webkit, :playwright, this)

    put(this, :selectors, SelectorsImpl.new())
    # apiRequest = new APIRequestImpl(this): not ported
    this
  end

  # upstream: PlaywrightImpl.java:81
  def local_utils(this), do: Connection.local_utils(this.connection)

  # upstream: PlaywrightImpl.java:90
  def chromium(this), do: get(this, :chromium)

  # upstream: PlaywrightImpl.java:95
  def firefox(this), do: get(this, :firefox)

  # upstream: PlaywrightImpl.java:105
  def webkit(this), do: get(this, :webkit)

  # upstream: PlaywrightImpl.java:110
  def selectors(this), do: get(this, :selectors)

  # upstream: PlaywrightImpl.java:115
  def close(this) do
    # playwright-cli will exit when its stdin is closed (the Port is closed when the Connection stops).
    Connection.close(this.connection)
  end
end
