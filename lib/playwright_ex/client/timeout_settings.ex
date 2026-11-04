defmodule PlaywrightEx.Client.TimeoutSettings do
  @upstream "packages/playwright-core/src/client/timeoutSettings.ts"
  @moduledoc "Port of `#{@upstream}`."
  import PlaywrightEx.Runtime.Heap

  defstruct [:guid, :loop, :heap]

  @default_playwright_timeout 30_000
  @default_playwright_launch_timeout 180_000

  def k_no_timeout, do: %{signal: nil, timeout: 0}

  def new(parent \\ nil) do
    this = new_object(__MODULE__)
    if parent, do: put(this, :_parent, parent)
    this
  end

  def set_default_timeout(this, timeout) do
    put(this, :_defaultTimeout, timeout)
  end

  def set_default_navigation_timeout(this, timeout) do
    put(this, :_defaultNavigationTimeout, timeout)
  end

  def default_navigation_timeout(this) do
    get(this, :_defaultNavigationTimeout)
  end

  def default_timeout(this) do
    get(this, :_defaultTimeout)
  end

  def navigation_timeout(this, options) do
    %{signal: options[:signal], timeout: _navigation_timeout(this, options)}
  end

  def timeout(this, options) do
    %{signal: options[:signal], timeout: _timeout(this, options)}
  end

  def launch_timeout(this, options) do
    %{signal: options[:signal], timeout: _launch_timeout(this, options)}
  end

  defp _navigation_timeout(this, options) do
    cond do
      is_number(options[:timeout]) -> options[:timeout]
      get(this, :_defaultNavigationTimeout) != nil -> get(this, :_defaultNavigationTimeout)
      debug_mode() == "inspector" -> 0
      get(this, :_defaultTimeout) != nil -> get(this, :_defaultTimeout)
      get(this, :_parent) -> _navigation_timeout(get(this, :_parent), options)
      true -> @default_playwright_timeout
    end
  end

  defp _timeout(this, options) do
    cond do
      is_number(options[:timeout]) -> options[:timeout]
      debug_mode() == "inspector" -> 0
      get(this, :_defaultTimeout) != nil -> get(this, :_defaultTimeout)
      get(this, :_parent) -> _timeout(get(this, :_parent), options)
      true -> @default_playwright_timeout
    end
  end

  defp _launch_timeout(this, options) do
    cond do
      is_number(options[:timeout]) -> options[:timeout]
      debug_mode() == "inspector" -> 0
      get(this, :_parent) -> _launch_timeout(get(this, :_parent), options)
      true -> @default_playwright_launch_timeout
    end
  end

  # utils/debug.ts debugMode()
  defp debug_mode, do: if(System.get_env("PWDEBUG") in ["1", "console"], do: "inspector")
end
