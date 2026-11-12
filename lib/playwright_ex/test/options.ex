defmodule PlaywrightEx.Test.Options do
  @moduledoc false
  # The options of `PlaywrightEx.Test`'s fragments: defaults, the merge over
  # `config :playwright_ex, :test`, and validation. Unknown keys and bad values raise
  # `ArgumentError`, as the facade's do.

  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Test.TestInfo

  # `isolate` is an argument only: as config it would isolate an in-test second `browser/1` too.
  @browser_keys [:browser_name, :launch_options, :driver, :on_start, :isolate]
  @artifact_keys [:trace, :screenshot, :video]
  @context_keys [:context_options]
  @config_only_keys [:output_dir, :workers, :snapshot_dir, :snapshot_path_template]
  @config_keys (@browser_keys -- [:isolate]) ++ @artifact_keys ++ @context_keys ++ @config_only_keys

  @driver_keys [:executable, :node, :cache_dir, :env]

  # Playwright Test's context option fixtures with no value given (`playwrightFixtures` in
  # `packages/playwright/src/index.ts`, as `_combinedContextOptions` collects them), as the client
  # takes them. Deviation: without `...contextOptions`, the config's `context_options` are
  # `new_context/2`'s only (facade options, converted by its call).
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

  @doc "The browser options: the config merged with `opts` (a keyword list)."
  def browser(opts), do: merge(@browser_keys, opts)

  @doc "The artifact options: the config merged with `opts`."
  def artifacts(opts), do: merge(@artifact_keys, opts)

  @doc "The context options: the config merged with `opts`."
  def context(opts), do: merge(@context_keys, opts)

  @doc """
  Adds the listener of `_setupArtifacts`' `runBeforeCreateBrowserContext` and
  `runBeforeCreateRequestContext` to `instrumentation`, once: in a marked test (or a process with
  it in `$callers`), each context gets the context defaults it does not give.
  """
  def ensure_context_defaults(instrumentation) do
    listener = %{
      runBeforeCreateBrowserContext: &__MODULE__.with_context_defaults/1,
      runBeforeCreateRequestContext: &__MODULE__.with_context_defaults/1
    }

    Heap.update(instrumentation, :listeners, &if(listener in &1, do: &1, else: &1 ++ [listener]))
  end

  @doc """
  Playwright Test's context option defaults, with the client's keys and values; `baseURL` is
  `process.env.PLAYWRIGHT_TEST_BASE_URL`.
  """
  def context_defaults do
    case System.get_env("PLAYWRIGHT_TEST_BASE_URL") do
      nil -> @context_defaults
      base_url -> Map.put(@context_defaults, :baseURL, base_url)
    end
  end

  @doc false
  # `if (!(key in options)) options[key] = value;`: a key given as `nil` (`undefined`) stays.
  def with_context_defaults(options),
    do: if(TestInfo.current(), do: Map.merge(context_defaults(), options), else: options)

  @doc "The root of the output dirs (config `output_dir`, default `test-results`)."
  def output_dir, do: config()[:output_dir]

  @doc "How many isolated drivers may run at once (config `workers`)."
  def workers, do: config()[:workers]

  @doc "The snapshot dir (config `snapshot_dir`, default `nil`: upstream's `testDir`)."
  def snapshot_dir, do: config()[:snapshot_dir]

  @doc "The snapshots' path template (config `snapshot_path_template`, default `nil`)."
  def snapshot_path_template, do: config()[:snapshot_path_template]

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

  # Option lists merge one level deep (`launch_options: [slow_mo: 50]` keeps the config's
  # `headless`).
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

  defp validate!(:on_start, nil), do: nil
  defp validate!(:on_start, fun) when is_function(fun, 1), do: fun
  defp validate!(:on_start, {m, f, a} = mfa) when is_atom(m) and is_atom(f) and is_list(a), do: mfa
  defp validate!(:isolate, value) when is_boolean(value), do: value

  defp validate!(key, mode) when is_map_key(@modes, key) and is_atom(mode) and mode != nil,
    do: artifact!(key, mode: mode)

  defp validate!(key, options) when is_map_key(@modes, key) and (is_list(options) or is_map(options)),
    do: artifact!(key, to_keyword(key, options))

  defp validate!(:output_dir, dir) when is_binary(dir), do: dir

  defp validate!(key, value)
       when key in [:snapshot_dir, :snapshot_path_template] and (value == nil or is_binary(value)),
       do: value

  defp validate!(:workers, workers) when is_integer(workers) and workers > 0, do: workers
  defp validate!(key, value), do: raise(ArgumentError, "invalid #{key}: #{inspect(value)}")

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
      else: raise(ArgumentError, "invalid #{key}: #{inspect(mode)}, expected one of #{inspect(@modes[key])}")
  end

  defp to_keyword(key, value) do
    cond do
      is_list(value) and Keyword.keyword?(value) -> value
      is_map(value) and not is_struct(value) -> Enum.to_list(value)
      true -> raise ArgumentError, "invalid #{key}: #{inspect(value)}, expected a keyword list or a map"
    end
  end
end
