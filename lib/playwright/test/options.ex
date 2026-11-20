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
    :test_id_attribute,
    :report_slow_tests
  ]
  @config_keys @pool_keys ++ @artifact_keys ++ @config_only_keys

  # `Playwright.Supervisor`'s `env` of each pooled driver: the driver itself is `config
  # :playwright, :driver`'s (`Playwright.Driver`), as `mix playwright.install` installs it.
  @driver_keys [:env]
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

  # The keys of the object forms, upstream's (`packages/playwright/types/test.d.ts`).
  @artifact_options %{
    trace: [:mode, :snapshots, :screenshots, :sources, :attachments],
    screenshot: [:mode, :full_page, :omit_background],
    video: [:mode, :size, :fps, :show]
  }

  @pool_label "Playwright.Test.BrowserPool.browser/1"

  # What `validate!/2` checks, for its error: upstream's `configLoader` checks (`preserveOutput`,
  # `workers`, `outputDir`), its browser fixture's (`browserName`), and `on_start`'s (Elixir only).
  # Other values pass as given, as upstream's do.
  @expected %{
    browser_name: "one of :chromium, :firefox, :webkit",
    on_start: "nil, a 1-arity function or an {m, f, a} tuple",
    output_dir: "a string",
    preserve_output: "one of :always, :never, :failures_only",
    workers: "a positive integer"
  }

  @config_label "config :playwright, :test"
  @doc """
  The pool options (`BrowserPool.browser/1`): the config, then `worker`, the calling scope's
  (`worker/3`), then `opts` (`launch_options` and `driver` one level deep).
  """
  def pool(opts, worker \\ []) do
    if !(is_list(opts) and Keyword.keyword?(opts)),
      do: raise(ArgumentError, "#{@pool_label}: expected a keyword list, got: #{inspect(opts)}")

    Playwright.Application.unknown_key!(@pool_label, "option", Keyword.keys(opts), @pool_keys)

    config = config()

    @pool_keys
    |> Map.new(&{&1, config[&1]})
    # The worker's replace the config's as a whole, as upstream's `launchOptions` fixture; the
    # call's `launch_options` merge over them per key.
    |> Map.merge(Map.new(worker))
    |> Map.merge(Map.new(opts), &merge_value/3)
    |> validate_all!(@pool_label)
  end

  @doc """
  The options of `use Playwright.Test`, validated, as a map: the recording modes, the timeouts
  and the worker options as the config takes them, the context options (`:context`) and
  `context_options`, converted. A `nil` option is kept: it wins over the earlier `use`s'
  (`merge/2`), then `layers/3` drops it, so the layer under gives the option.
  ExUnit.Case's keys are ignored (`without_ex_unit_keys/1`); of a duplicated key the later wins,
  as in JS's spread; an unknown key raises.
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
    {context, opts} = Keyword.split(opts, context_keys())

    # A device's, with its other keys: upstream's worker-scoped `defaultBrowserType` (`use/1`
    # raises for it).
    known = @use_keys ++ [:default_browser_type] ++ worker_keys

    with [_ | _] = unknown <- Enum.uniq(Keyword.keys(opts)) -- known do
      hint =
        " or a context option (#{Playwright.Application.key_names(Enum.sort(context_keys()))}). #{unknown_hint(unknown)}"

      Playwright.Application.unknown_key!(label, "option", unknown, known, hint)
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
    if :test_id_attribute in unknown,
      do:
        "test_id_attribute is config only: the client's value is global to the VM, which the tests " <>
          "running at once share, where upstream's is global to a worker, which runs one test at a time.",
      else: "The browser's other options are BrowserPool.browser/1's, the rest config's."
  end

  @doc """
  `Playwright.Test.use/1`: `opts` validated as `use_options/1`'s, as a keyword list for a tag,
  with a private key per option: `:"playwright.use.trace"` for a
  mode, `:"playwright.use.context.locale"` for a context option (its client key), next to
  `:"playwright.use.context_options"` for `context_options` as a whole, so
  ExUnit's merge of tags per key layers them per option, as upstream's, where each option is a
  fixture of its own. The keys are of the known options only.
  """
  def use(opts) do
    label = "Playwright.Test.use/1"
    # The worker's options too, for `@moduletag`: `Playwright.Test.test/3` raises for them in a
    # describe's or a test's tag (`worker_tags!/2`).
    {context, options} = label |> keyword!(opts) |> use_options!(label, @worker_keys) |> Map.pop(:context, %{})

    private = fn options, prefix ->
      for {key, value} <- options, do: {String.to_atom(prefix <> Atom.to_string(key)), value}
    end

    Enum.sort(private.(options, @use_prefix) ++ private.(context, @context_prefix))
  end

  # The one parameter of `parameters/1`: the project.
  @project_key :"playwright.project"

  @doc """
  `Playwright.Test.parameters/1`: a `Playwright.Test.Project` of `opts`, its `name` and the
  options of `use/1` and the worker's, under one private key, as a map for `parameterize:`.
  """
  def parameters(opts) do
    label = "Playwright.Test.parameters/1"
    {name, use} = Keyword.pop(keyword!(label, opts), :name)

    if !(name == nil or is_binary(name)),
      do: raise(ArgumentError, "#{label}: invalid value #{inspect(name)} for name, expected a string")

    # Upstream's default project name is `""`, which its reporters leave out: no name.
    name = if name != "", do: name

    %{@project_key => %Playwright.Test.Project{name: name, use: use_options!(use, label, @worker_keys)}}
  end

  @doc "The project of `parameters` (`parameters/1`'s, a module's `parameterize:` map), else `nil`."
  def project(parameters) do
    case parameters do
      %{@project_key => %Playwright.Test.Project{} = project} -> project
      _ -> nil
    end
  end

  @doc """
  Raises for a worker option (upstream's worker fixture, a device's `defaultBrowserType` too) in
  `tags`, those of `scope`: upstream's `_useFixtures` (`fixtures.ts`) for a `test.use` in a
  describe, a test's adapted ("in a test"). A module's `@moduletag` may have them, as upstream's
  top-level `test.use`.
  """
  def worker_tags!(tags, scope) do
    worker_keys =
      for key <- [:default_browser_type | @worker_keys], do: String.to_atom(@use_prefix <> Atom.to_string(key))

    for tag <- tags, {key, _value} <- List.wrap(tag), key in worker_keys do
      name = String.replace_prefix(Atom.to_string(key), @use_prefix, "")

      raise ArgumentError,
            "Playwright.Test.use/1: Cannot use({ #{name} }) in #{scope}, because it forces a new worker.\n" <>
              "Make it top-level in the test file or put in the configuration file."
    end

    :ok
  end

  @doc "Whether `key` is a private key of `use/1`."
  def use_key?(key), do: is_atom(key) and String.starts_with?(Atom.to_string(key), @use_prefix)

  @doc """
  The options of `use/1` in `map` (a test's or a module's tags), as `use_options/1`'s. No other
  key is read.
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
  The options of a test, or of a module's `setup_all`, by their layers: `project`, the options
  of the project in its `parameters` (`project/1`, upstream's `project.use`), and `module`, the
  module's `use_options` with the `use/1` options in its `tags` over them (`merge/2`; ExUnit
  merged a test's `@moduletag`, `@describetag` and `@tag` per option). A `nil` option is dropped
  from its layer (`unset_nil/1`).
  """
  def layers(parameters, use_options, tags) do
    project = project(parameters)
    %{project: unset_nil((project && project.use) || %{}), module: unset_nil(merge(use_options, used(tags)))}
  end

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
    # A map too.
    opts = keyword!("use Playwright.Test", opts)
    opts -- ExUnit.Case.__keys__(opts)
  end

  @doc """
  The recording modes of `layers` (`layers/3`): the module's and the tags' over the project's
  over the config's.
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
  `Playwright.Test.info/0`'s `use`: the resolved options of a registration (a test's or a
  module's `setup_all`'s), as `use Playwright.Test` takes them: its context options
  (`context_options/2`'s, by the facade's names, an enum's value as its atom), its timeouts, its
  recording modes and the worker options of its `BrowserPool.browser/1` calls.
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
  the `module`'s `browser_name` (`module_worker/2`'s: its `use`, then its `@moduletag`), else the
  `project`'s (`Playwright.Test.parameters/1`), else the config's if it sets one. Else the
  `default_browser_type` of the module, the project or the config (a spread device's; one in
  `context_options` doesn't count, as upstream's `contextOptions`), as upstream's `browserName`
  defaults to its `defaultBrowserType`, else the config's default, `:chromium`. A describe's or a
  test's tags don't count: the browser is the worker's. Whether the config sets one is the
  application env's: `config` has the default filled in.
  """
  def browser_name(config \\ config(), project \\ %{}, module \\ %{}) do
    env = Application.get_env(:playwright, :test, [])
    # The later of a duplicated key, as `config/0` takes it.
    configured =
      if Keyword.keyword?(env) and Playwright.Application.later_wins(env)[:browser_name] != nil,
        do: config.browser_name

    module[:browser_name] || project[:browser_name] || configured || module[:default_browser_type] ||
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
  calls, the same for its `setup_all` and each of its tests: `browser_name/3`, and the
  `launch_options` (the module's, else the project's, as a whole) and `connect_options` of the
  `module` (`module_worker/2`'s, or a module's `use_options`; a `nil` one dropped,
  `unset_nil/1`) or its `project` (`layers/3`'s, `nil`s dropped there).
  """
  def worker(config \\ config(), project \\ %{}, module \\ %{}) do
    module = unset_nil(module)
    keys = @worker_keys -- [:browser_name]
    options = merge(Map.take(project, keys), Map.take(module, keys))
    options |> Map.put(:browser_name, browser_name(config, project, module)) |> Enum.to_list()
  end

  @doc """
  The module's worker options: those of its `use_options`, then of `use/1` in its `@moduletag`s
  (`module_tags`, `ExUnit.TestModule`'s `tags`: all of them merged, the later per option), as
  upstream's top-level `test.use` applies file-wide. A describe's or a test's tags never count (`worker_tags!/2`).
  """
  def module_worker(use_options, module_tags) do
    worker_keys = [:default_browser_type | @worker_keys]
    merge(Map.take(use_options, worker_keys), Map.take(used(module_tags), worker_keys))
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

  @doc """
  Playwright Test's `testIdAttribute` (config `test_id_attribute`, default `data-testid`), `nil`
  for `""` (upstream's `if (testIdAttribute)` sets none: the selectors keep theirs).
  """
  def test_id_attribute, do: config()[:test_id_attribute]

  # Option lists merge one level deep (`launch_options: [slow_mo: 50]` keeps the config's
  # `headless`). The call's is checked first, so its error names the function.
  defp merge_value(key, config, value) when key in [:launch_options, :driver],
    do: Keyword.merge(to_keyword(key, config), validate!(key, value, @pool_label))

  defp merge_value(_key, _config, value), do: value

  @doc "`config :playwright, :test`, validated, with each key's default (`Playwright.Test.config/0`)."
  def config do
    config = Playwright.Application.config!(:test, @config_keys ++ context_keys())

    # A `nil` key is unset: its default.
    defaults()
    |> Map.merge(unset_nil(Map.new(config)))
    |> validate_all!(@config_label)
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
      test_id_attribute: "data-testid",
      report_slow_tests: [max: 5, threshold: 300_000]
    }
  end

  # `validate!/2`, its error naming the entry point `label`.
  defp validate!(key, value, label) do
    validate!(key, value)
  rescue
    error in ArgumentError -> reraise ArgumentError, "#{label}: " <> Exception.message(error), __STACKTRACE__
  end

  # A context option of the config is validated with the others (`context_options/2`).
  defp validate_all!(opts, label) do
    context_keys = context_keys()
    Map.new(opts, fn {key, value} -> {key, if(key in context_keys, do: value, else: validate!(key, value, label))} end)
  end

  # A device of `Playwright.devices/1` (the driver's) has it as a string.
  defp validate!(:default_browser_type, name) when name in ["chromium", "firefox", "webkit"],
    do: String.to_existing_atom(name)

  defp validate!(:browser_name, name) when name in [:chromium, :firefox, :webkit], do: name
  defp validate!(key, value) when key in [:launch_options, :context_options], do: to_keyword(key, value)

  defp validate!(:driver, driver) do
    driver = to_keyword(:driver, driver)
    keys!(:driver, driver, @driver_keys)
    driver
  end

  defp validate!(:connect_options, nil), do: nil

  defp validate!(:connect_options, options) do
    options = to_keyword(:connect_options, options)
    keys!(:connect_options, options, @connect_keys)
    Enum.sort(options)
  end

  defp validate!(:on_start, nil), do: nil
  defp validate!(:on_start, fun) when is_function(fun, 1), do: fun
  defp validate!(:on_start, {m, f, a} = mfa) when is_atom(m) and is_atom(f) and is_list(a), do: mfa

  defp validate!(key, options) when key in @artifact_keys and (is_list(options) or is_map(options)),
    do: artifact!(key, to_keyword(key, options))

  defp validate!(key, mode) when key in @artifact_keys, do: artifact!(key, mode: mode)

  defp validate!(:output_dir, dir) when is_binary(dir), do: dir
  defp validate!(:preserve_output, value) when value in [:always, :never, :failures_only], do: value

  # Upstream's `if (testIdAttribute)` (`_setupContextOptions`): an empty one sets none (`nil`),
  # so the selectors keep theirs.
  defp validate!(:test_id_attribute, ""), do: nil
  defp validate!(:workers, workers) when is_integer(workers) and workers > 0, do: workers
  # Upstream's `reportSlowTests: null`: none (a `nil` key is unset, its default).
  defp validate!(:report_slow_tests, false), do: false

  # Upstream's `reportSlowTests` (`{ max, threshold }`), as its configLoader validates it.
  defp validate!(:report_slow_tests, options) do
    options = to_keyword(:report_slow_tests, options)
    keys!(:report_slow_tests, options, [:max, :threshold])

    for key <- [:max, :threshold] do
      value = options[key]

      if !(is_number(value) and value >= 0),
        do:
          raise(
            ArgumentError,
            "invalid value #{inspect(value)} for report_slow_tests.#{key}, expected a non-negative number"
          )

      {key, value}
    end
  end

  defp validate!(key, value) when is_map_key(@expected, key),
    do: raise(ArgumentError, "invalid value #{inspect(value)} for #{key}, expected #{Map.fetch!(@expected, key)}")

  defp validate!(_key, value), do: value

  # Raises for the keys of `options` (the option `key`'s) that are not `allowed`.
  defp keys!(key, options, allowed) do
    case Enum.uniq(Keyword.keys(options)) -- allowed do
      [] ->
        :ok

      [unknown | _] ->
        raise ArgumentError,
              "unknown option #{key}.#{Playwright.Application.key_name(unknown)}, expected one of #{Playwright.Application.key_names(allowed)}"
    end
  end

  # An artifact option as a keyword list in `@artifact_options` order (an atom is its `mode`),
  # the trace's options defaulting to upstream's (`defaultTraceOptions` in
  # `packages/playwright/src/worker/testTracing.ts`); its values pass as given. No `mode` is
  # `:off` (`value.mode || 'off'`), the deprecated `:retry_with_trace` and `:retry_with_video`
  # `:on_first_retry`, as upstream's `startIfNeeded` and `normalizeVideoMode`.
  defp artifact!(key, options) do
    keys!(key, options, @artifact_options[key])

    defaults = if key == :trace, do: [snapshots: true, screenshots: true, sources: true, attachments: true], else: []
    options = defaults |> Keyword.merge(options) |> Keyword.put(:mode, mode(key, options[:mode]))

    for name <- @artifact_options[key], Keyword.has_key?(options, name), do: {name, options[name]}
  end

  defp mode(_key, nil), do: :off
  defp mode(:trace, :retry_with_trace), do: :on_first_retry
  defp mode(:video, :retry_with_video), do: :on_first_retry
  defp mode(_key, mode), do: mode

  # Of a duplicated key the later wins, as in JS's spread (`{ ...a, ...b }`), before any lookup.
  defp to_keyword(key, value) do
    cond do
      is_list(value) and Keyword.keyword?(value) ->
        Playwright.Application.later_wins(value)

      is_map(value) and not is_struct(value) ->
        Enum.to_list(value)

      true ->
        raise ArgumentError, "invalid value #{inspect(value)} for #{key}, expected a keyword list or a map"
    end
  end

  # `opts` of the entry point `label` as a keyword list.
  defp keyword!(label, opts) do
    to_keyword(:options, opts)
  rescue
    _ in ArgumentError ->
      reraise ArgumentError, "#{label}: expected a keyword list or a map, got: #{inspect(opts)}", __STACKTRACE__
  end
end
