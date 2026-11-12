defmodule PlaywrightEx.Test.Options do
  @moduledoc false
  # The options of `PlaywrightEx.Test` and `PlaywrightEx.Test.BrowserPool`: defaults, the merge
  # over `config :playwright_ex, :test`, the recording modes from tags over the config, and
  # validation. Unknown keys and bad values raise `ArgumentError`, as the facade's do.

  alias PlaywrightEx.Runtime.Facade

  @pool_keys [:browser_name, :launch_options, :connect_options, :driver, :on_start]
  @artifact_keys [:trace, :screenshot, :video]
  @config_only_keys [:context_options, :output_dir, :workers, :snapshot_dir, :snapshot_path_template]
  @config_keys @pool_keys ++ @artifact_keys ++ @config_only_keys

  @driver_keys [:executable, :node, :cache_dir, :env]
  # Playwright Test's `connectOptions`: `wsEndpoint` and `BrowserType.connect`'s options.
  @connect_keys [:ws_endpoint, :headers, :expose_network, :slow_mo, :timeout]

  # Playwright Test's context option fixtures with no value given (`playwrightFixtures` in
  # `packages/playwright/src/index.ts`, as `_combinedContextOptions` collects them), as the client
  # takes them.
  @context_defaults %{
    acceptDownloads: true,
    bypassCSP: false,
    colorScheme: "light",
    contrast: "no-preference",
    forcedColors: "none",
    hasTouch: false,
    ignoreHTTPSErrors: false,
    isMobile: false,
    javaScriptEnabled: true,
    locale: "en-US",
    offline: false,
    reducedMotion: "no-preference",
    viewport: %{width: 1280, height: 720},
    serviceWorkers: "allow"
  }

  @modes %{
    trace: [:off, :on, :retain_on_failure],
    screenshot: [:off, :on, :only_on_failure],
    video: [:off, :on, :retain_on_failure]
  }

  # The keys of the object forms, upstream's (`packages/playwright/types/test.d.ts`) but for
  # trace's `attachments` (of test steps, which our traces have none of) and video's `fps` and
  # `show`.
  @artifact_options %{
    trace: [:mode, :snapshots, :screenshots, :sources],
    screenshot: [:mode, :full_page, :omit_background],
    video: [:mode, :size]
  }

  @doc "The pool options (`BrowserPool.shared/1`, `exclusive/1`): the config merged with `opts`."
  def pool(opts) do
    if !Keyword.keyword?(opts), do: raise(ArgumentError, "expected a keyword list of options, got: #{inspect(opts)}")

    case Keyword.keys(opts) -- @pool_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options #{inspect(unknown)}, expected one of #{inspect(@pool_keys)}"
    end

    config = config()

    @pool_keys
    |> Map.new(&{&1, config[&1]})
    |> Map.merge(Map.new(opts), &merge_value/3)
    |> validate!()
  end

  @doc """
  The recording modes of a test: its tags (`@moduletag`, `@describetag`, `@tag`, which ExUnit
  merges in that order) over the config. `true` is `:on`, `false` is `:off`.
  """
  def artifacts(tags) do
    config = config()

    Map.new(@artifact_keys, fn key ->
      case tags do
        %{^key => value} -> {key, validate!(key, value)}
        _ -> {key, config[key]}
      end
    end)
  end

  @doc """
  `_combinedContextOptions`, as the client takes them: Playwright Test's context defaults, then
  the config's `context_options` (facade options, converted as `PlaywrightEx.Browser.new_context/2`
  converts them). `baseURL` defaults to `process.env.PLAYWRIGHT_TEST_BASE_URL`.
  """
  def context_options do
    defaults =
      case System.get_env("PLAYWRIGHT_TEST_BASE_URL") do
        nil -> @context_defaults
        base_url -> Map.put(@context_defaults, :baseURL, base_url)
      end

    type = PlaywrightEx.Browser.__options_type__(:new_context)
    Map.merge(defaults, Facade.options!(config()[:context_options], type, "browser.newContext"))
  end

  @doc "Playwright Test's context option defaults, with the client's keys and values."
  def context_defaults, do: @context_defaults

  @doc "The root of the output dirs (config `output_dir`, default `test-results`)."
  def output_dir, do: config()[:output_dir]

  @doc "How many exclusive drivers may run at once (config `workers`)."
  def workers, do: config()[:workers]

  @doc "The snapshot dir (config `snapshot_dir`, default `nil`: upstream's `testDir`)."
  def snapshot_dir, do: config()[:snapshot_dir]

  @doc "The snapshots' path template (config `snapshot_path_template`, default `nil`)."
  def snapshot_path_template, do: config()[:snapshot_path_template]

  # `connectOptionsFromEnv`: the `connect_options` default (the `connectOptions` fixture's), which
  # the config and the call replace, as `use: { connectOptions }` replaces the fixture.
  defp connect_options_from_env do
    case System.get_env("PW_TEST_CONNECT_WS_ENDPOINT") do
      blank when blank in [nil, ""] ->
        nil

      ws_endpoint ->
        headers = System.get_env("PW_TEST_CONNECT_HEADERS", "")

        Enum.reject(
          [
            ws_endpoint: ws_endpoint,
            headers: if(headers != "", do: JSON.decode!(headers)),
            expose_network: System.get_env("PW_TEST_CONNECT_EXPOSE_NETWORK")
          ],
          &match?({_key, nil}, &1)
        )
    end
  end

  # Option lists merge one level deep (`launch_options: [slow_mo: 50]` keeps the config's
  # `headless`).
  defp merge_value(key, config, value) when key in [:launch_options, :driver],
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
      connect_options: connect_options_from_env(),
      driver: [],
      on_start: nil,
      trace: :off,
      screenshot: :off,
      video: :off,
      context_options: [],
      output_dir: "test-results",
      workers: max(div(System.schedulers_online(), 2), 1),
      snapshot_dir: nil,
      snapshot_path_template: nil
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

  defp validate!(:connect_options, nil), do: nil

  defp validate!(:connect_options, options) do
    options = to_keyword(:connect_options, options)

    case Keyword.keys(options) -- @connect_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "unknown connect options #{inspect(unknown)}, expected one of #{inspect(@connect_keys)}"
    end

    if !is_binary(options[:ws_endpoint]),
      do: raise(ArgumentError, "connect options need :ws_endpoint, got: #{inspect(options)}")

    Enum.sort(options)
  end

  defp validate!(:on_start, nil), do: nil
  defp validate!(:on_start, fun) when is_function(fun, 1), do: fun
  defp validate!(:on_start, {m, f, a} = mfa) when is_atom(m) and is_atom(f) and is_list(a), do: mfa

  defp validate!(key, true) when is_map_key(@modes, key), do: artifact!(key, mode: :on)
  defp validate!(key, false) when is_map_key(@modes, key), do: artifact!(key, mode: :off)

  defp validate!(key, mode) when is_map_key(@modes, key) and is_atom(mode) and mode != nil,
    do: artifact!(key, mode: mode)

  defp validate!(key, options) when is_map_key(@modes, key) and (is_list(options) or is_map(options)),
    do: artifact!(key, to_keyword(key, options))

  defp validate!(:output_dir, dir) when is_binary(dir), do: dir

  defp validate!(key, value)
       when key in [:snapshot_dir, :snapshot_path_template] and (value == nil or is_binary(value)),
       do: value

  defp validate!(:workers, workers) when is_integer(workers) and workers > 0, do: workers

  defp validate!(key, value) when is_map_key(@modes, key),
    do: raise(ArgumentError, "invalid #{key}: #{inspect(value)}, expected one of #{inspect(accepted(key))}")

  defp validate!(key, value), do: raise(ArgumentError, "invalid #{key}: #{inspect(value)}")

  # What a mode option accepts, for the error.
  defp accepted(key), do: @modes[key] ++ [true, false, "[mode: _, ...]"]

  # An artifact option as a keyword list in `@artifact_options` order (an atom is its `mode`),
  # the trace's options defaulting to upstream's (`defaultTraceOptions` in
  # `packages/playwright/src/worker/testTracing.ts`). `mode` is required, as upstream's type
  # (`{ mode: TraceMode, ... }`) says: the option replaces the config's whole, so a list without
  # it would record nothing.
  defp artifact!(key, options) do
    if !Keyword.has_key?(options, :mode),
      do: raise(ArgumentError, "#{key} options need :mode, got: #{inspect(options)}")

    case Keyword.keys(options) -- @artifact_options[key] do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown #{key} options #{inspect(unknown)}, expected one of #{inspect(@artifact_options[key])}"
    end

    defaults = if key == :trace, do: [snapshots: true, screenshots: true, sources: true], else: []
    options = Keyword.merge(defaults, options)

    for name <- @artifact_options[key],
        Keyword.has_key?(options, name),
        do: {name, artifact_option!(key, name, options[name])}
  end

  defp artifact_option!(key, :mode, mode), do: mode!(key, mode)

  defp artifact_option!(_key, name, value)
       when name in [:snapshots, :screenshots, :sources, :full_page, :omit_background] and is_boolean(value),
       do: value

  # `{ dom?, aria?, screen? }`, a map as the facade's nested objects.
  defp artifact_option!(:trace, :snapshots, %{} = snapshots) when not is_struct(snapshots) do
    if Enum.all?(snapshots, fn {name, value} -> name in [:dom, :aria, :screen] and is_boolean(value) end),
      do: snapshots,
      else: raise(ArgumentError, "invalid trace snapshots: #{inspect(snapshots)}")
  end

  # A `ViewportSize`.
  defp artifact_option!(:video, :size, %{width: width, height: height} = size)
       when map_size(size) == 2 and is_integer(width) and is_integer(height),
       do: size

  defp artifact_option!(key, name, value), do: raise(ArgumentError, "invalid #{key} #{name}: #{inspect(value)}")

  defp mode!(key, mode) do
    if mode in @modes[key],
      do: mode,
      else: raise(ArgumentError, "invalid #{key}: #{inspect(mode)}, expected one of #{inspect(accepted(key))}")
  end

  defp to_keyword(key, value) do
    cond do
      is_list(value) and Keyword.keyword?(value) -> value
      is_map(value) and not is_struct(value) -> Enum.to_list(value)
      true -> raise ArgumentError, "invalid #{key}: #{inspect(value)}, expected a keyword list or a map"
    end
  end
end
