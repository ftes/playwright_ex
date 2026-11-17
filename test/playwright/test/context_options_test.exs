defmodule Playwright.Test.ContextOptionsTest do
  # `use Playwright.Test, ...` (through `Playwright.Case`), upstream's
  # `test.use({ locale: 'de-DE' })`: over the defaults and the config, under the call's options,
  # for every context of the module's tests and of its `setup_all`.
  use Playwright.Case, async: true, locale: "de-DE", color_scheme: :dark

  alias Playwright.Test.Options

  setup_all %{browser: browser} do
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close!(context) end)
    task_context = Task.await(Task.async(fn -> Browser.new_context!(browser) end))
    on_exit(fn -> BrowserContext.close!(task_context) end)
    %{setup_all_page: BrowserContext.new_page!(context), setup_all_task_page: BrowserContext.new_page!(task_context)}
  end

  def language(page), do: Page.evaluate!(page, "navigator.language")
  def dark?(page), do: Page.evaluate!(page, "matchMedia('(prefers-color-scheme: dark)').matches")

  test "the case's page gets them, over the defaults per key", %{page: page} do
    assert language(page) == "de-DE"
    assert dark?(page)
    assert Page.viewport_size(page) == %{width: 1280, height: 720}
  end

  test "a context the test creates gets them, the call's options win", %{browser: browser} do
    page = BrowserContext.new_page!(Browser.new_context!(browser))
    assert language(page) == "de-DE"

    page = BrowserContext.new_page!(Browser.new_context!(browser, locale: "it-IT"))
    assert language(page) == "it-IT"
    assert dark?(page)
  end

  test "a context a Task of the test creates gets them", %{browser: browser} do
    page = BrowserContext.new_page!(Task.await(Task.async(fn -> Browser.new_context!(browser) end)))
    assert language(page) == "de-DE"
    assert dark?(page)
  end

  test "the contexts of setup_all get them, a Task's too", ctx do
    for page <- [ctx.setup_all_page, ctx.setup_all_task_page] do
      assert language(page) == "de-DE"
      assert dark?(page)
    end
  end

  defp compile(name, body) do
    Code.compile_string("""
    defmodule Playwright.Test.ContextOptionsTest.#{name} do
      use ExUnit.Case
      #{body}
    end
    """)
  end

  test "a function or an invalid value raises at compile time" do
    for {name, function} <- [
          {"Anonymous", "fn _context -> [] end"},
          {"Capture", "&Playwright.Test.ContextOptionsTest.language/1"}
        ] do
      assert_raise ArgumentError, ~r/invalid context_options: .*a function isn't supported/, fn ->
        compile(name, "use Playwright.Case, context_options: #{function}")
      end
    end

    assert_raise ArgumentError, ~r/lokale/, fn ->
      compile("Unknown", "use Playwright.Test, lokale: \"de-DE\"")
    end

    assert_raise ArgumentError, ~r/invalid context_options: :dark, expected a keyword list/, fn ->
      compile("Invalid", "use Playwright.Test, context_options: :dark")
    end

    # A misspelled device.
    assert_raise ArgumentError, ~r/invalid context_options: nil, .*a device name that is not in/, fn ->
      compile("Nil", "use Playwright.Case, context_options: Playwright.devices()[\"iPhone13\"]")
    end

    assert_raise ArgumentError, ~r/invalid context_options: \{Mod, :fun\}, expected a keyword list/, fn ->
      compile("Tuple", "use Playwright.Test, context_options: {Mod, :fun}")
    end
  end

  test "Test.use validates as the use option, when the module compiles" do
    # A private key per option, with the client's key of a context option.
    assert [
             "playwright.use.context.colorScheme": "dark",
             "playwright.use.context.locale": nil,
             "playwright.use.trace": [mode: :on] ++ _
           ] = use = Playwright.Test.use(locale: nil, color_scheme: :dark, trace: :on)

    assert Enum.all?(Keyword.keys(use), &Options.use_key?/1)
    refute Options.use_key?(:context_options)
    assert Playwright.Test.use([]) == []

    assert Options.used(Map.new(use ++ [trace: :off, locale: "fr-FR"])) == %{
             context: %{colorScheme: "dark", locale: nil},
             trace: [mode: :on, snapshots: true, screenshots: true, sources: true, attachments: true]
           }

    for {message, options} <- [
          {~r/Playwright.Test.(use|parameters): .*lokale/, ~s(context_options: [lokale: "de-DE"])},
          {~r/invalid context_options: nil, .*a device name that is not in/,
           ~s|context_options: Playwright.devices()["iPhone13"]|},
          {~r/invalid context_options: .*a function isn't supported/, "context_options: &Function.identity/1"},
          {~r/unknown options \[:lokale\] for Playwright.Test.(use|parameters)/, ~s(lokale: "de-DE")},
          {~r/invalid trace: :sometimes/, "trace: :sometimes"},
          {~r/duplicated option :trace/, "trace: :on, trace: :off"}
        ] do
      assert_raise ArgumentError, message, fn ->
        compile("Tag", "use Playwright.Case\n@tag Playwright.Test.use(#{options})\ntest \"t\", do: :ok")
      end

      assert_raise ArgumentError, message, fn ->
        compile("Project", "use Playwright.Case, parameterize: [Playwright.Test.parameters(#{options})]")
      end
    end

    # A map too (a device).
    assert Playwright.Test.use(%{trace: :on}) == Playwright.Test.use(trace: :on)
    assert_raise ArgumentError, ~r/expected a keyword list or a map/, fn -> Playwright.Test.use(:on) end
  end

  test "one validator: an invalid value raises the same at each entry point, naming it" do
    entries = [
      {"use Playwright.Test", &"use Playwright.Case, #{&1}"},
      {"Playwright.Test.use", &"use Playwright.Case\n@tag Playwright.Test.use(#{&1})"},
      {"Playwright.Test.use", &"use Playwright.Case\n@describetag Playwright.Test.use(#{&1})"},
      {"Playwright.Test.parameters", &"use Playwright.Case, parameterize: [Playwright.Test.parameters(#{&1})]"}
    ]

    # Against the facade's types of `Browser.new_context/2`'s options, as that call checks them.
    values = [
      {"color_scheme: :purple",
       "invalid value :purple for :color_scheme, expected one of :dark, :light, :no_preference"},
      {"color_scheme: :purple", "invalid value :purple for :color_scheme, expected one of"},
      {"viewport: %{wide: 1}", "wide"},
      {"video: :sometimes", "invalid video: :sometimes"},
      {"action_timeout: -1", "invalid action_timeout: -1"},
      {"context_options: nil", "invalid context_options: nil"},
      {"lokale: 1", "unknown options [:lokale] for"}
    ]

    for {label, source} <- entries, {options, message} <- values do
      error = assert_raise ArgumentError, fn -> compile("Invalid", source.(options)) end
      assert error.message =~ label
      assert error.message =~ message
    end
  end

  test "browser_name is the module's or the project's: a tag's raises" do
    assert Playwright.Test.parameters(browser_name: :webkit, trace: :on) == %{
             "playwright.use.browser_name": :webkit,
             "playwright.use.trace": [mode: :on, snapshots: true, screenshots: true, sources: true, attachments: true]
           }

    assert %{browser_name: :firefox} = Options.use_options(browser_name: :firefox, async: true)
    assert_raise ArgumentError, ~r/invalid browser_name: :chrome/, fn -> Options.use_options(browser_name: :chrome) end

    assert_raise ArgumentError,
                 ~r/unknown options \[:browser_name\] for Playwright.Test.use.*forces a new worker/,
                 fn ->
                   compile("BrowserTag", "use Playwright.Case\n@tag Playwright.Test.use(browser_name: :webkit)")
                 end
  end

  test "the worker-scoped options raise in a describe's or a test's tag, test_id_attribute everywhere" do
    for option <- ["launch_options: [slow_mo: 1]", ~s|connect_options: [ws_endpoint: "ws://localhost"]|] do
      assert_raise ArgumentError, ~r/is worker-scoped, as upstream's, where it forces a new worker/, fn ->
        compile("WorkerTag", "use Playwright.Case\ndescribe \"d\" do\n@describetag Playwright.Test.use(#{option})\nend")
      end
    end

    for call <- [&Playwright.Test.use/1, &Playwright.Test.parameters/1, &Options.use_options/1] do
      assert_raise ArgumentError, ~r/test_id_attribute is config only: .*global to the VM/, fn ->
        call.(test_id_attribute: "data-test")
      end
    end
  end

  test "the worker options: the module's use over its project's over the config's, launch_options as a whole" do
    project = Options.used(Playwright.Test.parameters(launch_options: [slow_mo: 1, timeout: 5000]))
    use_options = Options.use_options(launch_options: %{slow_mo: 2}, connect_options: [ws_endpoint: "ws://localhost"])
    worker = Options.worker(Options.config(), project, use_options)

    assert worker[:launch_options] == [slow_mo: 2]
    assert Options.worker(Options.config(), project, %{})[:launch_options] == [slow_mo: 1, timeout: 5000]
    assert worker[:connect_options] == [ws_endpoint: "ws://localhost"]
    # The call's over them per key.
    assert %{launch_options: launch, connect_options: nil} =
             Options.pool([launch_options: [timeout: 5000], connect_options: nil], worker)

    assert Enum.sort(launch) == [slow_mo: 2, timeout: 5000]
    assert Options.pool([], Options.worker()) == Options.pool([])
  end

  test "the browser: an explicit browser_name (use, project, config), else a device's, else the default" do
    iphone = Playwright.Test.Options.use_options(Playwright.device("iPhone 13"))
    pixel = Options.used(Playwright.Test.parameters(Playwright.device("Pixel 7")))
    firefox = Options.used(Playwright.Test.parameters(browser_name: :firefox))
    config = Options.config()
    env = Application.get_env(:playwright, :test)
    # This suite's config sets one (`BROWSER`).
    assert Keyword.has_key?(env, :browser_name)

    assert Options.browser_name(config, firefox, Map.put(iphone, :browser_name, :chromium)) == :chromium
    assert Options.browser_name(config, firefox, iphone) == :firefox
    assert Options.browser_name(config, pixel, iphone) == config.browser_name
    assert Options.browser_name(config) == config.browser_name
    # The device's never reaches a context.
    layers = Options.layers(Playwright.Test.parameters(context_options: Playwright.device("Pixel 7")), iphone, %{})
    refute Map.has_key?(Options.context_options(config, layers), :defaultBrowserType)
  end

  test "a context option is an option of its own, over context_options at every level; a device is spread" do
    # A private key per option, and one for `context_options`; a describe's or a test's device
    # loses its browser.
    assert [
             "playwright.use.context.locale": "de-DE",
             "playwright.use.context_options": %{locale: "fr-FR"},
             "playwright.use.trace": _
           ] = Playwright.Test.use(locale: "de-DE", context_options: [locale: "fr-FR"], trace: :on)

    device = Playwright.device("iPhone 13")
    refute Enum.any?(Playwright.Test.use(device), fn {key, _value} -> to_string(key) =~ "rowser" end)
    assert Playwright.Test.parameters(device)[:"playwright.use.default_browser_type"] == :webkit
    assert Playwright.Test.parameters(device)[:"playwright.use.context.userAgent"] == device.user_agent
    assert %{default_browser_type: :webkit, context: %{isMobile: true}} = Options.use_options(device)

    config = %{context_options: [locale: "it-IT", color_scheme: :dark], timezone_id: "Europe/Rome"}
    assert %{locale: "it-IT", colorScheme: "dark", timezoneId: "Europe/Rome"} = Options.context_options(config)

    # The option over `context_options` of its level, and of a higher one: upstream's fixture
    # is the option's, and reads `contextOptions` only when no level sets it.
    parameters = Playwright.Test.parameters(locale: "de-DE", context_options: [locale: "fr-FR", offline: true])
    module = Options.use_options(context_options: [locale: "es-ES", has_touch: true])
    layers = %{project: Options.used(parameters), module: module}
    options = Options.context_options(config, layers)
    assert %{locale: "de-DE", hasTouch: true, timezoneId: "Europe/Rome"} = options
    # `context_options` is one option: the highest level's replaces the others as a whole.
    assert %{offline: false, colorScheme: "light"} = options

    # A `nil` option falls back to the level under it, then to `context_options`.
    layers = %{layers | module: Options.use_options(locale: nil, context_options: [locale: "es-ES"])}
    assert %{locale: "de-DE"} = Options.context_options(config, layers)
    layers = %{project: %{}, module: Options.use_options(locale: nil, context_options: [locale: "es-ES"])}
    assert %{locale: "es-ES"} = Options.context_options(config, layers)
  end

  test "context_options is upstream's contextOptions: replaced as a whole per level, under every option" do
    config = %{context_options: [locale: "fr-FR", timezone_id: "Europe/Paris"]}
    module = %{project: %{}, module: Options.use_options(context_options: [locale: "de-DE"])}
    # The config's alone, as before.
    assert %{locale: "fr-FR", timezoneId: "Europe/Paris"} = Options.context_options(config)
    options = Options.context_options(config, module)
    assert options.locale == "de-DE"
    refute Map.has_key?(options, :timezoneId)

    # An option of the config over a module's `context_options`.
    config = %{context_options: [], timezone_id: "UTC"}
    module = %{project: %{}, module: Options.use_options(context_options: [timezone_id: "Europe/Berlin"])}
    assert %{timezoneId: "UTC"} = Options.context_options(config, module)
    # Never deep-merged: `extra_http_headers` as a whole.
    config = %{context_options: [], extra_http_headers: %{"a" => "1", "b" => "2"}}
    module = %{project: %{}, module: Options.use_options(extra_http_headers: %{"a" => "3"})}
    assert %{extraHTTPHeaders: %{"a" => "3"}} = Options.context_options(config, module)
  end

  defp resolve(module), do: Options.context_options(%{context_options: []}, layers(module))
  defp layers(module, context \\ %{}), do: Options.layers(%{}, module.__playwright_test__(:options), context)

  test "a module's uses apply in order, each over the earlier per key" do
    assert %{colorScheme: "dark", locale: "fr-FR"} = resolve(__MODULE__.Merged)
  end

  test "a nil option resets it past the earlier uses, to the project's, the config's or the default" do
    # `[locale: "fr-FR"]`, then `[locale: nil]`.
    layers = layers(__MODULE__.NilOption)
    config = %{locale: "de-DE"}
    project = %{context: %{locale: "it-IT"}}

    assert %{locale: "de-DE", colorScheme: "dark"} = Options.context_options(config, layers)
    assert %{locale: "it-IT"} = Options.context_options(config, %{layers | project: project})
    assert %{locale: "en-US"} = Options.context_options(%{context_options: []}, layers)
    # A later option over the reset.
    assert %{colorScheme: "dark", locale: "it-IT"} = resolve(__MODULE__.NilThenOption)
    # The config's nil falls back to Playwright Test's default, the project's to the config's.
    assert %{locale: "en-US"} = Options.context_options(%{locale: nil})
    project = %{context: %{locale: nil, colorScheme: "dark"}}
    assert %{locale: "de-DE", colorScheme: "dark"} = Options.context_options(config, %{project: project, module: %{}})
  end

  test "the layers: the parameters' options are the project, the tags' over the module's use" do
    parameters = Playwright.Test.parameters(locale: "de-DE", color_scheme: :dark, video: :on)
    # Tags named as options are not read; a tag equal to the project's is the tag's.
    tags =
      Map.new(Playwright.Test.use(locale: "de-DE", trace: :on) ++ [video: false, locale: "es-ES"])

    use_options = %{screenshot: [mode: :on], context: %{locale: "it-IT", colorScheme: "light"}}
    layers = Options.layers(parameters, use_options, tags)

    assert layers.project == %{context: %{locale: "de-DE", colorScheme: "dark"}, video: [mode: :on]}
    assert %{locale: "de-DE", colorScheme: "light"} = Options.context_options(%{context_options: []}, layers)

    assert %{trace: [mode: :on] ++ _, video: [mode: :on], screenshot: [mode: :on]} =
             Options.artifacts(Options.config(), layers)

    # Without the tag, the module's over the project's.
    assert %{locale: "it-IT"} =
             Options.context_options(%{context_options: []}, Options.layers(parameters, use_options, %{}))
  end
end

defmodule Playwright.Test.ContextOptionsTest.ProjectTest do
  # `Playwright.Test.use/1` in a `parameterize:` map (upstream's `project.use`): over the config's,
  # under the module's `use` and the call's, for every context of the module, `setup_all`'s too.
  use Playwright.Case,
    async: true,
    parameterize:
      for(
        lang <- ["de-DE", "fr-FR"],
        do:
          Map.put(
            Playwright.Test.parameters(
              locale: lang,
              color_scheme: :dark,
              viewport: %{width: 400, height: 300}
            ),
            :lang,
            lang
          )
      ),
    color_scheme: :light

  import Playwright.Test.ContextOptionsTest, only: [language: 1, dark?: 1]

  setup_all %{browser: browser} do
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close!(context) end)
    task_context = Task.await(Task.async(fn -> Browser.new_context!(browser) end))
    on_exit(fn -> BrowserContext.close!(task_context) end)
    %{setup_all_page: BrowserContext.new_page!(context), setup_all_task_page: BrowserContext.new_page!(task_context)}
  end

  defp assert_project(page, lang) do
    assert language(page) == lang
    assert Page.viewport_size(page) == %{width: 400, height: 300}
    # The module's `use` over the project's.
    refute dark?(page)
  end

  test "the case's page gets the project's options, under the module's", %{page: page, lang: lang} do
    assert_project(page, lang)
  end

  test "a context the test creates gets them, the call's options win", %{browser: browser, lang: lang} do
    assert_project(BrowserContext.new_page!(Browser.new_context!(browser)), lang)

    page = BrowserContext.new_page!(Browser.new_context!(browser, locale: "it-IT", color_scheme: :dark))
    assert language(page) == "it-IT"
    assert dark?(page)
    assert Page.viewport_size(page) == %{width: 400, height: 300}
  end

  test "a context a Task of the test creates gets them", %{browser: browser, lang: lang} do
    context = Task.await(Task.async(fn -> Browser.new_context!(browser) end))
    assert_project(BrowserContext.new_page!(context), lang)
  end

  test "the contexts of setup_all get them, a Task's too", %{lang: lang} = ctx do
    assert_project(ctx.setup_all_page, lang)
    assert_project(ctx.setup_all_task_page, lang)
  end

  @tag Playwright.Test.use(extra_http_headers: %{"x-test" => "1"}, action_timeout: 1234, video: :retain_on_failure)
  test "Test.info().use: the test's resolved options, in a Task and by pid too", %{lang: lang, test_pid: test_pid} do
    use = Playwright.Test.info().use
    assert Task.await(Task.async(fn -> Playwright.Test.info().use end)) == use
    assert Playwright.Test.info(test_pid).use == use

    # The project's, the module's, the tag's and Playwright Test's defaults; an enum as its atom.
    assert %{locale: ^lang, color_scheme: :light, viewport: %{width: 400, height: 300}, offline: false} = use
    assert %{extra_http_headers: %{"x-test" => "1"}, action_timeout: 1234, navigation_timeout: :infinity} = use
    assert %{video: [mode: :retain_on_failure], trace: [mode: :off] ++ _, launch_options: _, connect_options: _} = use
    assert use.browser_name == String.to_atom(Playwright.TestBrowser.name())
    refute Map.has_key?(use, :base_url)
  end

  @tag Playwright.Test.use(locale: "es-ES")
  test "a test's tag over the module's and the project's", %{page: page} do
    assert language(page) == "es-ES"
    assert Page.viewport_size(page) == %{width: 400, height: 300}
    refute dark?(page)
  end

  # The context has one value for the key: the tag is read from the test's tags, not from it.
  @tag Playwright.Test.use(color_scheme: :dark)
  test "a tag equal to the project's option is over the module's", %{page: page, lang: lang} do
    assert language(page) == lang
    assert dark?(page)
  end

  test "the output dir is the same for the same options, whenever they compile", %{lang: lang} = ctx do
    options = [locale: lang, color_scheme: :dark, viewport: %{width: 400, height: 300}]
    parameters = Map.put(Playwright.Test.parameters(options), :lang, lang)
    {file, name} = {ctx.file, Playwright.Test.TestInfo.test_name(ctx)}

    assert Playwright.Test.info().output_dir ==
             Path.expand(
               Playwright.Test.TestInfo.output_dir(
                 Playwright.Test.Options.output_dir(),
                 file,
                 name,
                 __MODULE__,
                 parameters
               )
             )
  end
end

defmodule Playwright.Test.ContextOptionsTest.TagsTest do
  # `Playwright.Test.use/1` in tags: the module's, a describe's and a test's, each over the
  # earlier per option.
  use Playwright.Case, async: true, locale: "de-DE", color_scheme: :dark

  import Playwright.Test.ContextOptionsTest, only: [language: 1, dark?: 1]

  @moduletag Playwright.Test.use(locale: "fr-FR")

  # Before any test: later ones are of the tests after them.
  @moduletag Playwright.Test.use(trace: :retain_on_failure)

  setup_all %{browser: browser} do
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close!(context) end)
    %{setup_all_page: BrowserContext.new_page!(context)}
  end

  defp timezone(page), do: Page.evaluate!(page, "Intl.DateTimeFormat().resolvedOptions().timeZone")

  test "the module's tag over its use, in setup_all too", %{page: page, setup_all_page: setup_all_page} do
    for page <- [page, setup_all_page] do
      assert language(page) == "fr-FR"
      assert dark?(page)
    end
  end

  describe "a describe block" do
    @describetag Playwright.Test.use(timezone_id: "Europe/Berlin", locale: "it-IT")

    test "the describe's over the module's", %{page: page, browser: browser} do
      for page <- [page, BrowserContext.new_page!(Browser.new_context!(browser))] do
        assert timezone(page) == "Europe/Berlin"
        assert language(page) == "it-IT"
        assert dark?(page)
      end
    end

    @tag Playwright.Test.use(locale: "es-ES")
    test "a test's tag and its describe's both apply, the test's over it per option", %{page: page} do
      assert timezone(page) == "Europe/Berlin"
      assert language(page) == "es-ES"
      assert dark?(page)
    end

    @tag Playwright.Test.use(locale: "es-ES", color_scheme: :light)
    @tag Playwright.Test.use(locale: "pt-PT", trace: :retain_on_failure)
    test "two calls on one test layer per option, the later over the earlier", %{page: page} do
      assert timezone(page) == "Europe/Berlin"
      assert language(page) == "pt-PT"
      refute dark?(page)
      assert [mode: :retain_on_failure] ++ _ = Playwright.Test.Recorder.registration(self()).trace
    end

    @tag Playwright.Test.use(locale: nil)
    test "a nil option resets it to the config's or the default", %{page: page} do
      assert language(page) == "en-US"
    end

    test "the setup_all's contexts get no describe's options", %{setup_all_page: page} do
      assert language(page) == "fr-FR"
    end
  end

  test "a describe's options end with it", %{page: page} do
    assert language(page) == "fr-FR"
  end

  for {name, locale} <- [{"german", "de-AT"}, {"french", "fr-CA"}] do
    @tag Playwright.Test.use(locale: locale)
    test "a generated test's own options: #{name}", %{page: page} do
      assert language(page) == unquote(locale)
    end
  end
end

defmodule Playwright.Test.ContextOptionsTest.NotReadTest do
  # Only the keys of `Playwright.Test.use/1` are read: not a tag, a parameter or a callback's key
  # named as an option.
  use ExUnit.Case, async: true, parameterize: [%{lang: "de-DE", locale: "de-DE", trace: :on}]
  use Playwright.Test

  import Playwright.Test.ContextOptionsTest, only: [language: 1]

  alias Playwright.{Browser, BrowserContext}
  alias Playwright.Test.BrowserPool

  @moduletag locale: "it-IT"

  setup_all do
    browser = BrowserPool.browser()
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close!(context) end)
    %{browser: browser, setup_all_page: BrowserContext.new_page!(context), locale: "fr-FR"}
  end

  setup do
    %{locale: "es-ES"}
  end

  @tag locale: "pt-PT", trace: :on, video: :on, screenshot: :on
  test "a tag's, a parameter's or a callback's options are not read", %{browser: browser} = ctx do
    assert %{trace: :on, video: :on, screenshot: :on} = ctx
    assert language(BrowserContext.new_page!(Browser.new_context!(browser))) == "en-US"
    assert language(ctx.setup_all_page) == "en-US"

    assert %{trace: [mode: :off] ++ _, video: [mode: :off], screenshot: [mode: :off]} =
             Playwright.Test.Recorder.registration(self())
  end
end

defmodule Playwright.Test.ContextOptionsTest.SetupAllOrderTest do
  # In `setup_all`, ExUnit's context has the parameters over the module's tags, the reverse of a
  # test's: the layers are the same there, the project's under the module's use and tags.
  use Playwright.Case,
    async: true,
    parameterize: [
      Map.new(Playwright.Test.use(locale: "de-DE", color_scheme: :dark, timezone_id: "Europe/Berlin"))
    ],
    color_scheme: :light,
    timezone_id: "Europe/Rome"

  import Playwright.Test.ContextOptionsTest, only: [language: 1, dark?: 1]

  @moduletag Playwright.Test.use(locale: "fr-FR")

  setup_all %{browser: browser} do
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close!(context) end)
    %{setup_all_page: BrowserContext.new_page!(context)}
  end

  test "config < project < use < moduletag, in setup_all as in a test", %{page: page, setup_all_page: setup_all_page} do
    for page <- [page, setup_all_page] do
      assert language(page) == "fr-FR"
      refute dark?(page)
      assert Page.evaluate!(page, "Intl.DateTimeFormat().resolvedOptions().timeZone") == "Europe/Rome"
    end
  end
end

defmodule Playwright.Test.ContextOptionsTest.ParameterOverwrittenTest do
  # The project's options are those of ExUnit's parameters of the run: a `setup` that puts the
  # key in the context again changes nothing.
  use Playwright.Case,
    async: true,
    parameterize: [Playwright.Test.parameters(locale: "de-DE")]

  import Playwright.Test.ContextOptionsTest, only: [language: 1]

  setup do
    Playwright.Test.parameters(locale: "es-ES")
  end

  test "the project's options stay", %{page: page, browser: browser} do
    assert language(page) == "de-DE"
    assert language(BrowserContext.new_page!(Browser.new_context!(browser))) == "de-DE"
  end
end

defmodule Playwright.Test.ContextOptionsTest.DeviceBrowserTest do
  # Without a configured `browser_name`, a device's `default_browser_type` is the browser, as
  # upstream's `browserName` defaults to `defaultBrowserType`. Sync: it changes the config.
  use ExUnit.Case, async: false

  alias Playwright.Test.Options

  setup do
    env = Application.get_env(:playwright, :test)
    on_exit(fn -> Application.put_env(:playwright, :test, env) end)
    Application.put_env(:playwright, :test, Keyword.delete(env, :browser_name))
    %{env: env}
  end

  test "the module's device, else the project's, else the config's, else chromium", %{env: env} do
    iphone = Options.use_options(Playwright.device("iPhone 13"))
    firefox = Options.used(Playwright.Test.parameters(Playwright.device("Desktop Firefox")))
    # A device in `context_options` is no worker option.
    assert Options.browser_name(
             Options.config(),
             %{},
             Options.use_options(context_options: Playwright.device("iPhone 13"))
           ) ==
             :chromium

    config = Options.config()

    assert Options.browser_name(config) == :chromium
    assert Options.browser_name(config, firefox, iphone) == :webkit
    assert Options.browser_name(config, firefox, %{context: %{locale: "de-DE"}}) == :firefox
    assert Options.browser_name(config, firefox, %{browser_name: :chromium}) == :chromium

    Application.put_env(
      :playwright,
      :test,
      env |> Keyword.delete(:browser_name) |> Keyword.merge(Enum.to_list(Playwright.device("Desktop Firefox")))
    )

    assert Options.browser_name(Options.config()) == :firefox
    assert Options.context_options().userAgent == Playwright.device("Desktop Firefox").user_agent
  end
end

defmodule Playwright.Test.ContextOptionsTest.BrowserNameTest do
  # The module's `browser_name` is the default of `BrowserPool.browser/1`, in `setup_all`, a test
  # and their Tasks. Not launched: CI installs one browser.
  use ExUnit.Case,
    async: true,
    parameterize: [
      Playwright.Test.parameters(browser_name: :firefox, launch_options: [slow_mo: 1]),
      Playwright.Test.parameters(Playwright.device("iPhone 13"))
    ]

  use Playwright.Test, browser_name: :webkit

  alias Playwright.Test.Recorder

  setup_all do
    %{
      setup_all_worker: Recorder.worker_options(),
      setup_all_task_worker: Task.await(Task.async(&Recorder.worker_options/0))
    }
  end

  test "the use option over the project's, for setup_all's calls and a test's own", ctx do
    assert ctx.setup_all_worker[:browser_name] == :webkit
    assert ctx.setup_all_task_worker == ctx.setup_all_worker
    assert Recorder.worker_options() == ctx.setup_all_worker
    assert Task.await(Task.async(&Recorder.worker_options/0)) == ctx.setup_all_worker
    assert Playwright.Test.info().use.browser_name == :webkit
    assert %{browser_name: :webkit} = Playwright.Test.Options.pool([], ctx.setup_all_worker)
    assert %{browser_name: :chromium} = Playwright.Test.Options.pool([browser_name: :chromium], ctx.setup_all_worker)
  end
end

defmodule Playwright.Test.ContextOptionsTest.LaunchOptionsProjectTest do
  # A project's `launch_options` are its worker's: a pooled browser of its own key.
  use Playwright.Case,
    async: true,
    parameterize: for(n <- [1, 2], do: Map.put(Playwright.Test.parameters(launch_options: [slow_mo: n]), :slow_mo, n))

  test "the case's browser is the project's worker's", %{browser: browser, slow_mo: slow_mo} do
    keys =
      for {_pid, %{key: {_, _, _, launch_options, _}}} <- :sys.get_state(Playwright.Test.Pool).seats,
          do: launch_options

    assert Enum.any?(keys, &(&1[:slow_mo] == slow_mo))
    # A test's own call gets the module's worker.
    assert BrowserPool.browser() == browser
    assert BrowserPool.browser(launch_options: [slow_mo: 3]) != browser
  end
end

defmodule Playwright.Test.ContextOptionsTest.TimeoutsTest do
  # `action_timeout` and `navigation_timeout` are test-scoped: every level sets them.
  use Playwright.Case, async: true, action_timeout: 4000, navigation_timeout: 5000

  alias Playwright.Test.Recorder

  setup_all %{browser: browser} do
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close!(context) end)
    %{setup_all_page: BrowserContext.new_page!(context)}
  end

  defp click_timeout(page) do
    Page.set_content!(page, "<p>none</p>")
    assert {:error, %Playwright.TimeoutError{message: message}} = Locator.click(Page.locator(page, "button"))
    message
  end

  test "the module's", %{test_pid: test_pid} do
    assert Recorder.registration(test_pid).timeouts == %{action_timeout: 4000, navigation_timeout: 5000}
  end

  describe "a describe block" do
    @describetag Playwright.Test.use(action_timeout: 300)

    test "the describe's over the module's, for the test's contexts", %{page: page, test_pid: test_pid} do
      assert Recorder.registration(test_pid).timeouts == %{action_timeout: 300, navigation_timeout: 5000}
      assert click_timeout(page) =~ "Timeout 300ms exceeded"
    end

    @tag Playwright.Test.use(action_timeout: 200)
    test "the test's over the describe's", %{page: page} do
      assert click_timeout(page) =~ "Timeout 200ms exceeded"
    end
  end
end

defmodule Playwright.Test.ContextOptionsTest.ConfigTest do
  # The module's options over the config's, per key. Sync, so the config here reaches no other
  # module.
  use ExUnit.Case, async: false

  import Playwright.Test.ContextOptionsTest, only: [language: 1]

  alias Playwright.TestServer

  # Before `use Playwright.Case`, whose registrations read the config.
  setup_all do
    server = TestServer.server(start_supervised!({TestServer, dir_path: System.tmp_dir!()}))
    TestServer.set_content(server, "/", "<p>home</p>", "text/html")

    config = Application.get_env(:playwright, :test)
    on_exit(fn -> Application.put_env(:playwright, :test, config) end)

    Application.put_env(
      :playwright,
      :test,
      Keyword.put(config, :context_options, base_url: server.prefix, locale: "de-DE")
    )

    %{server: server}
  end

  use Playwright.Case, locale: "fr-FR"

  test "the module's options win over the config's, which apply to the other keys", ctx do
    assert language(ctx.page) == "fr-FR"
    Page.goto!(ctx.page, "/")
    assert Page.url(ctx.page) == ctx.server.prefix <> "/"
  end
end

defmodule Playwright.Test.ContextOptionsTest.OtherTest do
  # A module without them keeps the defaults.
  use Playwright.Case, async: true

  import Playwright.Test.ContextOptionsTest, only: [language: 1, dark?: 1]

  test "another module's options don't reach this one", %{page: page} do
    assert language(page) == "en-US"
    refute dark?(page)
  end
end

defmodule Playwright.Test.ContextOptionsTest.Merged do
  # No tests: its `use`s' merged options.
  use ExUnit.Case, async: true
  use Playwright.Test, locale: "de-DE", color_scheme: :dark
  use Playwright.Test, %{locale: "fr-FR"}
end

defmodule Playwright.Test.ContextOptionsTest.NilOption do
  use ExUnit.Case, async: true
  use Playwright.Test, locale: "fr-FR", color_scheme: :dark
  use Playwright.Test, locale: nil
end

defmodule Playwright.Test.ContextOptionsTest.NilThenOption do
  use ExUnit.Case, async: true
  use Playwright.Test, locale: "fr-FR", color_scheme: :dark
  use Playwright.Test, locale: nil
  use Playwright.Test, locale: "it-IT"
end
