defmodule PlaywrightEx.Test.Options do
  @moduledoc false
  # The options of `PlaywrightEx.Test`'s fragments: defaults, the merge over
  # `config :playwright_ex, :test`, and validation. Unknown keys and bad values raise
  # `ArgumentError`, as the facade's do.

  @browser_keys [:browser_name, :launch_options, :driver, :on_start, :isolate]
  @artifact_keys [:trace, :screenshot, :video]
  @context_keys [:context_options]
  @config_only_keys [:output_dir, :max_isolated]
  @config_keys @browser_keys ++ @artifact_keys ++ @context_keys ++ @config_only_keys

  @driver_keys [:executable, :node, :cache_dir, :env]

  @modes %{
    trace: [:off, :on, :retain_on_failure],
    screenshot: [:off, :on, :only_on_failure],
    video: [:off, :on, :retain_on_failure]
  }

  @formatter PlaywrightEx.Test.Formatter

  @doc "The browser options: the config merged with `opts` (a keyword list)."
  def browser(opts), do: merge(@browser_keys, opts)

  @doc "The artifact options: the config merged with `opts`."
  def artifacts(opts), do: merge(@artifact_keys, opts)

  @doc "The context options: the config merged with `opts`."
  def context(opts), do: merge(@context_keys, opts)

  @doc "The root of the output dirs (config `output_dir`, default `test-results`)."
  def output_dir, do: config()[:output_dir]

  @doc "How many isolated drivers may run at once (config `max_isolated`)."
  def max_isolated, do: config()[:max_isolated]

  defp merge(keys, opts) do
    if !Keyword.keyword?(opts), do: raise(ArgumentError, "expected a keyword list of options, got: #{inspect(opts)}")

    case Keyword.keys(opts) -- keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options #{inspect(unknown)}, expected one of #{inspect(keys)}"
    end

    config = config()

    keys
    |> Map.new(&{&1, config[&1]})
    |> Map.merge(Map.new(opts), &merge_value/3)
    |> validate!()
  end

  # Option lists merge one level deep (`launch_options: [slow_mo: 50]` keeps the config's `headless`).
  defp merge_value(key, config, value) when key in [:launch_options, :context_options, :driver],
    do: Keyword.merge(to_keyword(key, config), to_keyword(key, value))

  defp merge_value(_key, _config, value), do: value

  defp config do
    config = Application.get_env(:playwright_ex, :test, [])

    if !Keyword.keyword?(config),
      do: raise(ArgumentError, "config :playwright_ex, :test must be a keyword list, got: #{inspect(config)}")

    case Keyword.keys(config) -- @config_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown keys #{inspect(unknown)} in config :playwright_ex, :test"
    end

    defaults()
    |> Map.merge(Map.new(config))
    |> validate!()
  end

  defp defaults do
    %{
      browser_name: :chromium,
      launch_options: [],
      driver: [],
      on_start: nil,
      isolate: false,
      trace: :off,
      screenshot: :off,
      video: :off,
      context_options: [],
      output_dir: "test-results",
      max_isolated: max(div(System.schedulers_online(), 2), 1)
    }
  end

  defp validate!(opts) do
    Map.new(opts, fn {key, value} -> {key, validate!(key, value)} end)
  end

  defp validate!(:browser_name, name) when name in [:chromium, :firefox, :webkit], do: name
  defp validate!(key, value) when key in [:launch_options, :context_options], do: to_keyword(key, value)

  defp validate!(:driver, driver) do
    driver = to_keyword(:driver, driver)

    case Keyword.keys(driver) -- @driver_keys do
      [] ->
        driver

      unknown ->
        raise ArgumentError, "unknown driver options #{inspect(unknown)}, expected one of #{inspect(@driver_keys)}"
    end
  end

  defp validate!(:on_start, nil), do: nil
  defp validate!(:on_start, fun) when is_function(fun, 1), do: fun
  defp validate!(:on_start, {m, f, a} = mfa) when is_atom(m) and is_atom(f) and is_list(a), do: mfa
  defp validate!(:isolate, isolate) when is_boolean(isolate), do: isolate
  defp validate!(key, mode) when is_map_key(@modes, key) and is_atom(mode) and mode != nil, do: mode!(key, mode)
  defp validate!(:output_dir, dir) when is_binary(dir), do: dir
  defp validate!(:max_isolated, max) when is_integer(max) and max > 0, do: max
  defp validate!(key, value), do: raise(ArgumentError, "invalid #{key}: #{inspect(value)}")

  defp mode!(key, mode) do
    if mode in @modes[key],
      do: mode,
      else: raise(ArgumentError, "invalid #{key}: #{inspect(mode)}, expected one of #{inspect(@modes[key])}")
  end

  defp to_keyword(key, value) do
    cond do
      is_list(value) and Keyword.keyword?(value) -> value
      is_map(value) and not is_struct(value) -> Enum.to_list(value)
      true -> raise ArgumentError, "invalid #{key}: #{inspect(value)}, expected a keyword list or a map"
    end
  end

  @doc """
  Raises unless `PlaywrightEx.Test.Formatter` is one of `formatters`, for the options that need
  it (`what`).
  """
  def require_formatter!(what, formatters \\ ExUnit.configuration()[:formatters] || []) do
    if @formatter not in formatters do
      raise ArgumentError, """
      #{what} needs PlaywrightEx.Test.Formatter, add it in test/test_helper.exs:

          ExUnit.start(formatters: [ExUnit.CLIFormatter, PlaywrightEx.Test.Formatter])
      """
    end

    :ok
  end
end
