defmodule Playwright.Test.Options do
  @moduledoc false
  # The options of `Playwright.Test` and `Playwright.Test.BrowserPool`: defaults, the merge
  # over `config :playwright, :test`, the recording modes from tags and `use` options over the
  # config, and validation. Unknown keys and bad values raise `ArgumentError`, as the facade's do.

  alias Playwright.Runtime.Facade

  @pool_keys [:browser_name, :launch_options, :connect_options, :driver, :on_start]
  @artifact_keys [:trace, :screenshot, :video]
  # `use Playwright.Test`'s: upstream's options of `test.use`, the worker-scoped modes and the
  # test-scoped context options.
  @use_keys @artifact_keys ++ [:tags, :context_options]
  @config_only_keys [
    :context_options,
    :action_timeout,
    :navigation_timeout,
    :output_dir,
    :preserve_output,
    :workers,
    :snapshot_dir,
    :snapshot_path_template,
    :test_id_attribute
  ]
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

  # Upstream's `TraceMode`, `ScreenshotMode`, `VideoMode` (`overrides-test.d.ts`).
  @retry_modes [:on_first_retry, :on_all_retries, :retain_on_first_failure, :retain_on_failure_and_retries]
  @modes %{
    trace: [:off, :on, :retain_on_failure | @retry_modes],
    screenshot: [:off, :on, :only_on_failure, :on_first_failure],
    video: [:off, :on, :retain_on_failure | @retry_modes]
  }

  # The keys of the object forms, upstream's (`packages/playwright/types/test.d.ts`).
  @artifact_options %{
    trace: [:mode, :snapshots, :screenshots, :sources, :attachments],
    screenshot: [:mode, :full_page, :omit_background],
    video: [:mode, :size, :fps, :show]
  }

  @doc "The pool options (`BrowserPool.browser/1`): the config merged with `opts`."
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
  The options of `use Playwright.Test`, validated, as a map: the recording modes as the config
  takes them, `tags` (a boolean, `true` by default) whether the test's tags set them, and
  `context_options`, the options or a function (see `use_context_options/2`). ExUnit.Case's keys
  are ignored (`without_ex_unit_keys/1`); any other key, a duplicated one or a bad value raises.
  """
  def use_options(opts) do
    opts = without_ex_unit_keys(opts)
    keys = Keyword.keys(opts)

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [key | _] -> raise ArgumentError, "duplicated option #{inspect(key)} for use Playwright.Test"
    end

    case keys -- @use_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown options #{inspect(unknown)} for use Playwright.Test, expected one of #{inspect(@use_keys)} " <>
                "(the browser's options are BrowserPool.browser/1's, the rest config's)"
    end

    Map.new(opts, fn
      {:tags, tags} when is_boolean(tags) -> {:tags, tags}
      {:tags, tags} -> raise ArgumentError, "invalid tags: #{inspect(tags)}, expected a boolean"
      {:context_options, options} -> {:context_options, use_context_options!(options)}
      {key, value} -> {key, validate!(key, value)}
    end)
  end

  # `context_options:` of `use Playwright.Test` (upstream's `test.use({ locale: 'de-DE' })`, or an
  # option fixture's function), as a list of what the module's `use`s give, in order: the options
  # (a keyword list or a map), converted as the registration's, or a function of the test's ExUnit
  # context returning them. The `use` options are evaluated at compile time and kept in the
  # module, so the function is an external capture (`&Mod.fun/1`) or `{Mod, :fun}`: an anonymous
  # one can't be stored. Whether the function exists is checked when it's called: its module may
  # not be compiled yet, but `Mod` must name a module (an Elixir alias, or one that is loaded), so
  # a mistyped option (`{:color_scheme, :dark}`) raises here.
  defp use_context_options!(fun) when is_function(fun, 1) do
    case Function.info(fun, :type) do
      {:type, :external} ->
        [fun]

      _local ->
        raise ArgumentError,
              "invalid context_options: an anonymous function can't be kept in the module at compile time, " <>
                "use an external capture (&MyApp.BrowserCase.context_options/1) or {MyApp.BrowserCase, :context_options}"
    end
  end

  defp use_context_options!({module, function} = mf) when is_atom(module) and is_atom(function) do
    if !(String.starts_with?(Atom.to_string(module), "Elixir.") or Code.ensure_loaded?(module)),
      do:
        raise(
          ArgumentError,
          "invalid context_options: #{inspect(mf)}, expected options (a keyword list or a map), " <>
            "an external capture (&Mod.fun/1) or {Mod, :fun} of a module"
        )

    [mf]
  end

  defp use_context_options!(options) when is_function(options),
    do: raise(ArgumentError, "invalid context_options: #{inspect(options)}, expected a function of arity 1")

  defp use_context_options!(options), do: [context_options!(options, "use Playwright.Test: ")]

  @doc """
  The module's `use` option `context_options` (`use_options/1`) for the test of the ExUnit
  `context`, converted: the options and the functions' results for `context`, each over those
  before it. An option given as `nil` resets it past every earlier `use`, to the config's or the
  default, as upstream's `undefined` override (`_appendFixtureList`). For a module's `setup_all`
  (`context` `nil`) the options only if no `use` gives a function, else none: a function is of a
  test's context, and applying only the rest would break the order and the resets.
  """
  def use_context_options(options, context) do
    uses = Map.get(options, :context_options, [])

    if context == nil and not Enum.all?(uses, &is_map/1) do
      %{}
    else
      uses
      |> Enum.reduce(%{}, fn
        %{} = static, acc -> Map.merge(acc, static)
        function, acc -> Map.merge(acc, call_context_options!(function, context))
      end)
      |> Map.reject(fn {_key, value} -> value == nil end)
    end
  end

  defp call_context_options!(function, context) do
    {module, name} = function_name(function)
    label = "#{inspect(module)}.#{name}/1"

    if !(Code.ensure_loaded?(module) and function_exported?(module, name, 1)),
      do: raise(ArgumentError, "context_options: #{inspect(function)} is undefined (no #{label})")

    context_options!(apply(module, name, [context]), "context_options: #{label} returned an invalid option: ")
  end

  defp function_name({module, name}), do: {module, name}

  defp function_name(fun) do
    {:module, module} = Function.info(fun, :module)
    {:name, name} = Function.info(fun, :name)
    {module, name}
  end

  # Options (a keyword list or a map) as the client takes them, a `nil` one kept as `nil` (a
  # reset, `use_context_options/2`); an invalid one raises with `prefix`.
  defp context_options!(options, prefix) do
    :context_options
    |> to_keyword(options)
    |> Facade.options!(Playwright.Browser.__options_type__(:new_context), "browser.newContext")
  rescue
    error in ArgumentError -> reraise ArgumentError, prefix <> Exception.message(error), __STACKTRACE__
  end

  @doc """
  `opts` without ExUnit.Case's own `use` keys (`:async` and the rest, as `ExUnit.Case.__keys__/1`
  takes them for `use ExUnit.CaseTemplate`'s modules), so a case template forwards its options to
  `use Playwright.Test` as is.
  """
  def without_ex_unit_keys(opts) do
    if !Keyword.keyword?(opts),
      do: raise(ArgumentError, "use Playwright.Test expects a keyword list of options, got: #{inspect(opts)}")

    opts -- ExUnit.Case.__keys__(opts)
  end

  @doc """
  The recording modes of a test: its tags (`@moduletag`, `@describetag`, `@tag`, which ExUnit
  merges in that order) over the module's `use` options (`use_options/1`) over the config;
  without its tags under `tags: false`. `true` is `:on`, `false` is `:off`.
  """
  def artifacts(tags, config \\ config(), options \\ %{}) do
    tags = if Map.get(options, :tags, true), do: tags, else: %{}

    Map.new(@artifact_keys, fn key ->
      case tags do
        %{^key => value} -> {key, validate!(key, value)}
        _ -> {key, Map.get(options, key, config[key])}
      end
    end)
  end

  @doc """
  `_combinedContextOptions`, as the client takes them: Playwright Test's context defaults, then
  the config's `context_options`, then the module's (`use_context_options/2`, converted), each a
  key over the one before (facade options, converted as `Playwright.Browser.new_context/2`
  converts them); a `nil` one falls back to the one under it.
  Upstream's `PLAYWRIGHT_TEST_BASE_URL` default is not read: config only.
  """
  def context_options(config \\ config(), module_options \\ %{}) do
    config_options =
      config[:context_options]
      |> context_options!("config :playwright, :test: ")
      |> Map.reject(fn {_key, value} -> value == nil end)

    @context_defaults
    |> Map.merge(config_options)
    |> Map.merge(module_options)
  end

  @doc """
  Playwright Test's `actionTimeout` and `navigationTimeout` (config `action_timeout`,
  `navigation_timeout`): `%{action_timeout: _, navigation_timeout: _}`, each `:infinity` by
  default (upstream's `0`, no timeout).
  """
  def timeouts(config \\ config()), do: Map.take(config, [:action_timeout, :navigation_timeout])

  @doc """
  ExUnit's timeout for `tags` (`get_timeout/2` in `ExUnit.Runner`): `:infinity` under `mix test
  --trace`, else the `timeout` tag or `mix test --timeout`. A test's tags, or a module's for its
  `setup_all`.
  """
  def ex_unit_timeout(tags) do
    config = ExUnit.configuration()
    if config[:trace], do: :infinity, else: Map.get(tags, :timeout, config[:timeout])
  end

  @doc "Playwright Test's context option defaults, with the client's keys and values."
  def context_defaults, do: @context_defaults

  @doc "The root of the output dirs (config `output_dir`, default `test-results`)."
  def output_dir, do: config()[:output_dir]

  @doc "Upstream's `preserveOutput` (config `preserve_output`, default `:always`)."
  def preserve_output(config \\ config()), do: config.preserve_output

  @doc "How many pooled drivers may run at once (config `workers`)."
  def workers, do: config()[:workers]

  @doc "The snapshot dir (config `snapshot_dir`, default `nil`: upstream's `testDir`)."
  def snapshot_dir, do: config()[:snapshot_dir]

  @doc "The snapshots' path template (config `snapshot_path_template`, default `nil`)."
  def snapshot_path_template, do: config()[:snapshot_path_template]

  @doc "Playwright Test's `testIdAttribute` (config `test_id_attribute`, default `data-testid`)."
  def test_id_attribute, do: config()[:test_id_attribute]

  # Option lists merge one level deep (`launch_options: [slow_mo: 50]` keeps the config's
  # `headless`).
  defp merge_value(key, config, value) when key in [:launch_options, :driver],
    do: Keyword.merge(to_keyword(key, config), to_keyword(key, value))

  defp merge_value(_key, _config, value), do: value

  @doc "`config :playwright, :test`, validated, with each key's default (`Playwright.Test.config/0`)."
  def config do
    config = Application.get_env(:playwright, :test, [])

    if !Keyword.keyword?(config),
      do: raise(ArgumentError, "config :playwright, :test must be a keyword list, got: #{inspect(config)}")

    case Keyword.keys(config) -- @config_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown keys #{inspect(unknown)} in config :playwright, :test, expected one of #{inspect(@config_keys)}"
    end

    defaults()
    |> Map.merge(Map.new(config))
    |> validate!()
  end

  defp defaults do
    %{
      browser_name: :chromium,
      launch_options: [],
      connect_options: nil,
      driver: [],
      on_start: nil,
      trace: :off,
      screenshot: :off,
      video: :off,
      context_options: [],
      action_timeout: :infinity,
      navigation_timeout: :infinity,
      output_dir: "test-results",
      preserve_output: :always,
      workers: max(div(System.schedulers_online(), 2), 1),
      snapshot_dir: nil,
      snapshot_path_template: nil,
      test_id_attribute: "data-testid"
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
  defp validate!(:preserve_output, value) when value in [:always, :never, :failures_only], do: value

  defp validate!(key, value)
       when key in [:snapshot_dir, :snapshot_path_template] and (value == nil or is_binary(value)),
       do: value

  defp validate!(:test_id_attribute, name) when is_binary(name) and name != "", do: name
  defp validate!(:workers, workers) when is_integer(workers) and workers > 0, do: workers

  # Milliseconds, `0` or `:infinity` for none (`BrowserContext.set_default_timeout/2`'s).
  defp validate!(key, timeout)
       when key in [:action_timeout, :navigation_timeout] and
              (timeout == :infinity or (is_integer(timeout) and timeout >= 0)),
       do: timeout

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

    defaults = if key == :trace, do: [snapshots: true, screenshots: true, sources: true, attachments: true], else: []
    options = Keyword.merge(defaults, options)

    for name <- @artifact_options[key],
        Keyword.has_key?(options, name),
        do: {name, artifact_option!(key, name, options[name])}
  end

  defp artifact_option!(key, :mode, mode), do: mode!(key, mode)

  defp artifact_option!(_key, name, value)
       when name in [:snapshots, :screenshots, :sources, :attachments, :full_page, :omit_background] and
              is_boolean(value),
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

  defp artifact_option!(:video, :fps, fps) when is_integer(fps) and fps > 0, do: fps

  # `{ actions?: recordVideo.showActions, test?: { level?, position?, fontSize? } }`, maps with
  # upstream's keys and values; `actions` goes to the context's `recordVideo` as is.
  defp artifact_option!(:video, :show, %{} = show) when not is_struct(show) do
    valid? =
      Enum.all?(show, fn
        {:actions, %{} = actions} ->
          Map.keys(actions) -- [:duration, :position, :fontSize, :cursor, :style] == []

        {:test, %{} = test} ->
          Map.keys(test) -- [:level, :position, :fontSize] == [] and test[:level] in [nil, "file", "title", "step"]

        _ ->
          false
      end)

    if valid?, do: show, else: raise(ArgumentError, "invalid video show: #{inspect(show)}")
  end

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
