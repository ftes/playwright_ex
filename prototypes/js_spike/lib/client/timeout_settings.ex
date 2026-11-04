# upstream: packages/playwright-core/src/client/timeoutSettings.ts
defmodule PlaywrightJS.Client.TimeoutSettings do
  import PlaywrightJS.Runtime.Heap

  defstruct [:guid, :conn]

  @default_playwright_timeout 30_000
  @default_playwright_launch_timeout 180_000

  # upstream: timeoutSettings.ts:26
  def k_no_timeout, do: %{signal: nil, timeout: 0}

  # upstream: timeoutSettings.ts:33
  # `new TimeoutSettings()` without a loop yields an immutable value object.
  def new(loop, parent \\ nil) do
    this = if loop, do: new_object(loop, __MODULE__), else: %__MODULE__{}
    if parent, do: put(this, :_parent, parent)
    this
  end

  # upstream: timeoutSettings.ts:37
  def set_default_timeout(this, timeout) do
    put(this, :_defaultTimeout, timeout)
  end

  # upstream: timeoutSettings.ts:41
  def set_default_navigation_timeout(this, timeout) do
    put(this, :_defaultNavigationTimeout, timeout)
  end

  # upstream: timeoutSettings.ts:45
  def default_navigation_timeout(this) do
    get(this, :_defaultNavigationTimeout)
  end

  # upstream: timeoutSettings.ts:49
  def default_timeout(this) do
    get(this, :_defaultTimeout)
  end

  # upstream: timeoutSettings.ts:53
  def navigation_timeout(this, options) do
    %{signal: options[:signal], timeout: _navigation_timeout(this, options)}
  end

  # upstream: timeoutSettings.ts:57
  def timeout(this, options) do
    %{signal: options[:signal], timeout: _timeout(this, options)}
  end

  # upstream: timeoutSettings.ts:61
  def launch_timeout(this, options) do
    %{signal: options[:signal], timeout: _launch_timeout(this, options)}
  end

  # upstream: timeoutSettings.ts:65
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

  # upstream: timeoutSettings.ts:79
  defp _timeout(this, options) do
    cond do
      is_number(options[:timeout]) -> options[:timeout]
      debug_mode() == "inspector" -> 0
      get(this, :_defaultTimeout) != nil -> get(this, :_defaultTimeout)
      get(this, :_parent) -> _timeout(get(this, :_parent), options)
      true -> @default_playwright_timeout
    end
  end

  # upstream: timeoutSettings.ts:91
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
