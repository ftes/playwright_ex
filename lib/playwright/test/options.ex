defmodule Playwright.Test.Options do
  @moduledoc false
  # The options of `Playwright.Test` and `Playwright.Test.BrowserPool`: defaults, the merge
  # over `config :playwright, :test`, the layers of `use` options (a module's, and those
  # `Playwright.Test.use/1` and `parameters/1` put in tags and parameters) over the config, and
  # validation. Unknown keys and bad values raise `ArgumentError`, as the facade's do.

  alias Playwright.Runtime.Facade

  @pool_keys [:browser_name, :launch_options, :connect_options, :driver, :on_start]
  @artifact_keys [:trace, :screenshot, :video]
  # `use Playwright.Test`'s and `Playwright.Test.use/1`'s: upstream's options of `test.use` that
  # a describe block or a test may set.
  @timeout_keys [:action_timeout, :navigation_timeout]
  @use_keys @artifact_keys ++ [:context_options] ++ @timeout_keys
  # Upstream's worker-scoped `browserName`, `launchOptions` and `connectOptions`: a module's or a
  # project's, not a describe's or a test's. (Its `trace`, `screenshot` and `video` are too:
  # here they are per test.)
  @worker_keys [:browser_name, :launch_options, :connect_options]
  # Upstream's context option fixtures (`acceptDownloads: [({ contextOptions }, use) => ...]` in
  # `packages/playwright/src/index.ts`), by the client's keys: options of their own, each over
  # its key of `context_options` (upstream's `contextOptions`).
  @context_fixtures [
    :acceptDownloads,
    :bypassCSP,
    :colorScheme,
    :contrast,
    :deviceScaleFactor,
    :extraHTTPHeaders,
    :forcedColors,
    :geolocation,
    :hasTouch,
    :httpCredentials,
    :ignoreHTTPSErrors,
    :isMobile,
    :javaScriptEnabled,
    :locale,
    :offline,
    :permissions,
    :proxy,
    :reducedMotion,
    :screen,
    :storageState,
    :clientCertificates,
    :timezoneId,
    :userAgent,
    :viewport,
    :baseURL,
    :serviceWorkers
  ]
  # The prefixes of the private keys of `use/1`: an option's, and a context option's.
  @use_prefix "playwright.use."
  @context_prefix @use_prefix <> "context."
  @config_only_keys [
    :context_options,
    :default_browser_type,
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

  @doc """
  The pool options (`BrowserPool.browser/1`): the config, then `worker`, the calling scope's
  (`worker/3`), then `opts` (`launch_options` and `driver` one level deep).
  """
  def pool(opts, worker \\ []) do
    if !Keyword.keyword?(opts), do: raise(ArgumentError, "expected a keyword list of options, got: #{inspect(opts)}")

    case Keyword.keys(opts) -- @pool_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options #{inspect(unknown)}, expected one of #{inspect(@pool_keys)}"
    end

    config = config()

    @pool_keys
    |> Map.new(&{&1, config[&1]})
    # The worker's replace the config's as a whole, as upstream's `launchOptions` fixture; the
    # call's `launch_options` merge over them per key.
    |> Map.merge(Map.new(worker))
    |> Map.merge(Map.new(opts), &merge_value/3)
    |> validate!()
  end

  @doc """
  The options of `use Playwright.Test`, validated, as a map: the recording modes, the timeouts
  and the worker options as the config takes them, the context options (`:context`) and
  `context_options`, converted. A `nil` option is kept: it wins over the earlier `use`s'
  (`merge/2`), then `layers/3` drops it, so the layer under gives the option.
  ExUnit.Case's keys are ignored (`without_ex_unit_keys/1`); any other key, a duplicated one or
  a bad value raises.
  """
  def use_options(opts), do: opts |> without_ex_unit_keys() |> use_options!("use Playwright.Test", @worker_keys)

  @doc "The context options that are options of their own (`@context_fixtures`), as the facade names them."
  def context_keys do
    {:object, schema} = Playwright.Browser.__options_type__(:new_context)
    for {key, {js_key, _type}} <- schema, js_key in @context_fixtures, do: key
  end

  @doc """
  Upstream's option fixtures as this runner has them, for `mix playwright.parity`: `scopes`,
  each by upstream's name with where it can be set (`:test`: every level, `:worker`: a module
  or a project, `:config`), and `defaults`, the context options' defaults.
  """
  def fixtures do
    scope = fn names, scope -> Map.new(names, &{Atom.to_string(&1), scope}) end

    %{
      scopes:
        scope.(@context_fixtures ++ [:contextOptions, :actionTimeout, :navigationTimeout], :test)
        |> Map.merge(scope.([:trace, :screenshot, :video], :test))
        |> Map.merge(scope.([:browserName, :defaultBrowserType, :launchOptions, :connectOptions], :worker))
        |> Map.merge(scope.([:testIdAttribute], :config)),
      defaults: Map.new(@context_defaults, fn {name, value} -> {Atom.to_string(name), value} end)
    }
  end

  defp use_options!(opts, label, worker_keys) do
    keys = Keyword.keys(opts)
    {context, opts} = Keyword.split(opts, context_keys())

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [key | _] -> raise ArgumentError, "duplicated option #{inspect(key)} for #{label}"
    end

    # A device's, with its other keys: upstream's worker-scoped `defaultBrowserType`, which a
    # describe's or a test's `use/1` drops (`private/3`).
    known = @use_keys ++ [:default_browser_type] ++ worker_keys

    case Keyword.keys(opts) -- known do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown options #{inspect(unknown)} for #{label}, expected one of #{inspect(known)} or a " <>
                "context option as #{inspect(Enum.sort(context_keys()))} (#{unknown_hint(unknown)})"
    end

    options =
      Map.new(opts, fn
        {key, nil} -> {key, nil}
        {:context_options, options} -> {:context_options, context_options!(options, "#{label}: ")}
        {key, value} -> {key, validate!(key, value, label)}
      end)

    if context == [], do: options, else: Map.put(options, :context, context_options!(context, "#{label}: "))
  end

  # Why `unknown` are no options of a `use`.
  defp unknown_hint(unknown) do
    cond do
      :test_id_attribute in unknown ->
        "test_id_attribute is config only: the client's value is global to the VM, which the tests " <>
          "running at once share, where upstream's is global to a worker, which runs one test at a time"

      unknown -- @worker_keys == [] ->
        "#{Enum.map_join(unknown, ", ", &to_string/1)} is worker-scoped, as upstream's, where it forces a " <>
          "new worker in a describe: set it for the module (`use Playwright.Case, #{hd(unknown)}: _`) or " <>
          "its project (`Playwright.Test.parameters/1`)"

      true ->
        "the browser's other options are BrowserPool.browser/1's, the rest config's"
    end
  end

  @doc """
  `Playwright.Test.use/1`: `opts` validated as `use_options/1`'s, as a keyword list for a tag
  or a `parameterize:` map, with a private key per option: `:"playwright.use.trace"` for a
  mode, `:"playwright.use.context.locale"` for a context option (its client key), next to
  `:"playwright.use.context_options"` for `context_options` as a whole, so
  ExUnit's merge of tags per key layers them per option, as upstream's, where each option is a
  fixture of its own. The keys are of the known options only.
  """
  def use(opts), do: private(opts, "Playwright.Test.use", [])

  @doc "`Playwright.Test.parameters/1`: as `use/1`, with the worker options too, as a map for `parameterize:`."
  def parameters(opts), do: Map.new(private(opts, "Playwright.Test.parameters", @worker_keys))

  defp private(opts, label, worker_keys) do
    opts = to_keyword(label, opts)
    options = use_options!(opts, label, worker_keys)
    # In a describe's or a test's, a device's browser is ignored: the browser is the worker's.
    options = if worker_keys == [], do: Map.delete(options, :default_browser_type), else: options
    {context, options} = Map.pop(options, :context, %{})

    private = fn options, prefix ->
      for {key, value} <- options, do: {String.to_atom(prefix <> Atom.to_string(key)), value}
    end

    Enum.sort(private.(options, @use_prefix) ++ private.(context, @context_prefix))
  end

  @doc "Whether `key` is a private key of `use/1`."
  def use_key?(key), do: is_atom(key) and String.starts_with?(Atom.to_string(key), @use_prefix)

  @doc """
  The options of `use/1` in `map` (a test's or a module's parameters or tags), as
  `use_options/1`'s. No other key is read.
  """
  def used(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      case is_atom(key) and Atom.to_string(key) do
        @context_prefix <> name ->
          Map.update(acc, :context, %{String.to_atom(name) => value}, &Map.put(&1, String.to_atom(name), value))

        @use_prefix <> name ->
          Map.put(acc, String.to_atom(name), value)

        _other ->
          acc
      end
    end)
  end

  @doc """
  The options of a test, or of a module's `setup_all`, by their layers: `project`, the `use/1`
  options in its `parameters` (the module's `parameterize:` map, upstream's `project.use`), and
  `module`, the module's `use_options` with the `use/1` options in its `tags` over them (`merge/2`;
  ExUnit merged a test's `@moduletag`, `@describetag` and `@tag` per option). A `nil` option is
  dropped from its layer (`unset_nil/1`).
  """
  def layers(parameters, use_options, tags),
    do: %{project: unset_nil(used(parameters)), module: unset_nil(merge(use_options, used(tags)))}

  # Upstream's `undefined` option: no value at its layer, so the layer under gives the option, in
  # the end its default. A `test.use` of it goes back to the config's and the project's
  # (`_appendFixtureList`), past the file's and the describes' own; the project's and the config's
  # are skipped (`mergeObjects`, `takeFirst`). Of every option, one level deep: the context
  # options of their own (`:context`) too.
  defp unset_nil(options) do
    for {key, value} <- options, value != nil, into: %{} do
      if key == :context, do: {key, unset_nil(value)}, else: {key, value}
    end
  end

  @doc """
  `options` over `past`, both `use_options/1`'s: the later wins per key, the context options of
  their own (`:context`) per option, as upstream's `test.use` calls (each option its own
  fixture), and the `context_options` bag as a whole, as upstream's one `contextOptions` fixture.
  A `nil` wins as any value does, so `layers/3` drops the option past the earlier ones.
  """
  def merge(past, options) do
    Map.merge(past, options, fn
      :context, past, options -> Map.merge(past, options)
      _key, _past, options -> options
    end)
  end

  # Options (a keyword list or a map) as the client takes them, a `nil` one kept as `nil` (unset:
  # `unset_nil/1` drops a context option's in `layers/3` and `config/0`, `context_options/2` a
  # bag's key); an invalid one raises with `prefix`. A function is not
  # options: upstream's option fixtures (`test.use({ locale: async ({}, use) => ... })`) aren't
  # ported.
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
    # A map too: a device (`use Playwright.Test, Playwright.device("iPhone 13")`).
    opts = to_keyword("use Playwright.Test", opts)
    opts -- ExUnit.Case.__keys__(opts)
  end

  @doc """
  The recording modes of `layers` (`layers/3`): the module's and the tags' over the project's
  over the config's. `true` is `:on`, `false` is `:off`.
  """
  def artifacts(config \\ config(), layers \\ %{project: %{}, module: %{}}), do: layered(@artifact_keys, config, layers)

  defp layered(keys, config, layers),
    do: Map.new(keys, &{&1, Map.get(layers.module, &1, Map.get(layers.project, &1, config[&1]))})

  @doc """
  `_combinedContextOptions`, as the client takes them: Playwright Test's context defaults, then
  the config's `context_options`, then those of `layers` (`layers/3`), the project's, then the
  module's and the tags', each a key over the one before (facade options, converted as
  `Playwright.Browser.new_context/2` converts them). A `nil` key of a `context_options` is
  none, as upstream's fixture reads it (`contextOptions.locale ?? 'en-US'`).
  Upstream's `PLAYWRIGHT_TEST_BASE_URL` default is not read: config only.
  """
  def context_options(config \\ config(), layers \\ %{project: %{}, module: %{}}) do
    prefix = "config :playwright, :test: "
    # `contextOptions`, one fixture: the highest level's, as a whole.
    bag =
      layers.module[:context_options] || layers.project[:context_options] ||
        context_options!(config[:context_options] || [], prefix)

    # Each context option, a fixture of its own.
    options =
      [context_options!(Map.take(config, context_keys()), prefix), layers.project[:context], layers.module[:context]]
      |> Enum.reduce(%{}, &Map.merge(&2, &1 || %{}))

    @context_defaults
    |> Map.merge(Map.reject(bag, fn {_key, value} -> value == nil end))
    |> Map.merge(options)
    # A device's in `context_options`: not a context's option.
    |> Map.delete(:defaultBrowserType)
  end

  @doc """
  `Playwright.Test.info/0`'s `use`: the resolved options of a registration (a test's), as
  `use Playwright.Test` takes them: its context options (`context_options/2`'s, by the facade's
  names, an enum's value as its atom), its timeouts, its recording modes and the worker options
  of its `BrowserPool.browser/1` calls.
  """
  def resolved(test) do
    {:object, schema} = Playwright.Browser.__options_type__(:new_context)
    names = Map.new(schema, fn {key, {js_key, type}} -> {js_key, {key, type}} end)

    context =
      Map.new(test.context_options, fn {js_key, value} ->
        case names[js_key] do
          {key, {:enum, values}} -> {key, Enum.find_value(values, value, fn {atom, wire} -> wire == value && atom end)}
          {key, _type} -> {key, value}
          nil -> {js_key, value}
        end
      end)

    context
    |> Map.merge(test.timeouts)
    # The modes as given, not as the retry makes them (`trace: :on_first_retry`).
    |> Map.merge(test.use_modes)
    |> Map.merge(Map.take(pool([], test.worker), @worker_keys))
  end

  @doc """
  Upstream's `browserName` of a module's run, for its `BrowserPool.browser/1` calls without one:
  the module's `use_options`' `browser_name`, else the `project`'s (`Playwright.Test.parameters/1`),
  else the config's if it sets one. Else the `default_browser_type` of the module's
  `use_options`, the project's or the config's (a spread device's; one in `context_options`
  doesn't count, as upstream's `contextOptions`), as upstream's `browserName` defaults to its
  `defaultBrowserType`, else the config's default, `:chromium`. Tags don't
  count: the browser is the worker's. Whether the config sets one is the application env's:
  `config` has the default filled in.
  """
  def browser_name(config \\ config(), project \\ %{}, use_options \\ %{}) do
    env = Application.get_env(:playwright, :test, [])
    configured = if Keyword.keyword?(env) and env[:browser_name] != nil, do: config.browser_name

    use_options[:browser_name] || project[:browser_name] || configured || use_options[:default_browser_type] ||
      project[:default_browser_type] || config[:default_browser_type] || config.browser_name
  end

  @doc """
  Playwright Test's `actionTimeout` and `navigationTimeout` (`action_timeout`,
  `navigation_timeout`) of `layers` over the config's: `%{action_timeout: _, navigation_timeout:
  _}`, each `:infinity` by default (upstream's `0`, no timeout).
  """
  def timeouts(config \\ config(), layers \\ %{project: %{}, module: %{}}), do: layered(@timeout_keys, config, layers)

  @doc """
  The worker options of a module's run, over the config's, for its `BrowserPool.browser/1`
  calls: `browser_name/3`, and the `launch_options` (the module's, else the project's, as a whole)
  and `connect_options` of the module's `use_options` (a `nil` one dropped, `unset_nil/1`) or its
  `project` (`layers/3`'s, `nil`s dropped there).
  """
  def worker(config \\ config(), project \\ %{}, use_options \\ %{}) do
    use_options = unset_nil(use_options)
    keys = @worker_keys -- [:browser_name]
    options = merge(Map.take(project, keys), Map.take(use_options, keys))
    options |> Map.put(:browser_name, browser_name(config, project, use_options)) |> Enum.to_list()
  end

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

    case Keyword.keys(config) -- (@config_keys ++ context_keys()) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown keys #{inspect(unknown)} in config :playwright, :test, expected one of " <>
                "#{inspect(@config_keys)} or a context option (locale, viewport, ...)"
    end

    # A `nil` key is unset: its default.
    defaults()
    |> Map.merge(unset_nil(Map.new(config)))
    |> validate!()
  end

  defp defaults do
    %{
      browser_name: :chromium,
      default_browser_type: nil,
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

  # `validate!/2`, its error naming the entry point `label`.
  defp validate!(key, value, label) do
    validate!(key, value)
  rescue
    error in ArgumentError -> reraise ArgumentError, "#{label}: " <> Exception.message(error), __STACKTRACE__
  end

  # A context option of the config is validated with the others (`context_options/2`).
  defp validate!(opts) do
    context_keys = context_keys()
    Map.new(opts, fn {key, value} -> {key, if(key in context_keys, do: value, else: validate!(key, value))} end)
  end

  defp validate!(:default_browser_type, nil), do: nil
  defp validate!(:default_browser_type, name) when name in [:chromium, :firefox, :webkit], do: name

  defp validate!(:default_browser_type, name) when name in ["chromium", "firefox", "webkit"],
    do: String.to_existing_atom(name)

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

  defp validate!(key, mode) when is_map_key(@modes, key) and is_atom(mode),
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
