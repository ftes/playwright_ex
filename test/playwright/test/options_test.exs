defmodule Playwright.Test.OptionsTest do
  use ExUnit.Case, async: true

  alias Playwright.Test.BrowserPool
  alias Playwright.Test.Options

  # The modes of `use` options over the config's.
  defp artifacts(options),
    do: Options.artifacts(Options.config(), Options.layers(%{}, Options.use_options(Map.to_list(options)), %{}))

  describe "validation" do
    test "options that are not a keyword list raise, naming the function" do
      for {label, fun} <- [
            {"Playwright.Supervisor.start_link/1", fn -> apply(Playwright.Supervisor, :start_link, [[:x]]) end},
            {"Playwright.Test.attach/2", fn -> Playwright.Test.attach("x", [:x]) end},
            {"Playwright.Test.snapshot_path/2", fn -> Playwright.Test.snapshot_path("x.png", [:x]) end},
            {"Playwright.Test.step/3", fn -> Playwright.Test._step(:pass, "x", fn -> :ok end, [:x]) end}
          ] do
        assert_raise ArgumentError, "#{label}: expected a keyword list, got: [:x]", fun
      end
    end

    test "config :playwright takes :test, :expect and :driver" do
      assert Playwright.Application.validate_env!([{:test, []}, {:expect, []}, {:driver, []}]) == :ok

      for {key, name} <- [{:tests, "tests"}, {Playwright.Test.GitHubFormatter, "Playwright.Test.GitHubFormatter"}] do
        assert_raise ArgumentError,
                     "config :playwright: unknown key #{name}, expected one of test, expect, driver",
                     fn -> Playwright.Application.validate_env!([{key, []}]) end
      end
    end

    test "a driver option of the pool other than :env raises: the driver is config :playwright, :driver's" do
      for key <- [:executable, :node, :cache_dir] do
        assert_raise ArgumentError,
                     "Playwright.Test.BrowserPool.browser/1: unknown option driver.#{key}, expected one of env",
                     fn -> Options.pool(driver: [{key, "x"}]) end
      end
    end

    test "unknown options raise before anything starts" do
      assert_raise ArgumentError, ~r/unknown option headless, /, fn ->
        BrowserPool.browser(headless: true)
      end

      assert_raise ArgumentError, ~r/unknown option driver.name, /, fn -> Options.pool(driver: [name: Foo]) end
    end

    test "bad values raise" do
      assert_raise ArgumentError, ~r/invalid value :chrome for browser_name, /, fn ->
        Options.pool(browser_name: :chrome)
      end

      assert_raise ArgumentError, ~r/invalid value .* for on_start, /, fn -> Options.pool(on_start: fn -> :ok end) end

      # Merged over the config's, they name the function too.
      for key <- [:launch_options, :driver] do
        assert_raise ArgumentError,
                     ~s(Playwright.Test.BrowserPool.browser/1: invalid value "x" for #{key}, expected a keyword list or a map),
                     fn -> Options.pool([{key, "x"}]) end
      end

      assert_raise ArgumentError, ~r/expected a keyword list/, fn -> Options.pool([:driver]) end
    end

    test "connect options: BrowserType.connect's and ws_endpoint" do
      assert %{connect_options: [headers: %{"a" => "b"}, slow_mo: 1, ws_endpoint: "ws://x"]} =
               Options.pool(connect_options: %{ws_endpoint: "ws://x", slow_mo: 1, headers: %{"a" => "b"}})

      assert %{connect_options: nil} = Options.pool(connect_options: nil)

      assert_raise ArgumentError, ~r/unknown option connect_options.launch_options, /, fn ->
        Options.pool(connect_options: [ws_endpoint: "ws://x", launch_options: []])
      end

      # Its value isn't checked, as upstream's.
      assert %{connect_options: [timeout: 1]} = Options.pool(connect_options: [timeout: 1])
    end

    test "options are as given, keyword lists or maps; modes unchecked, as upstream's" do
      assert %{launch_options: [slow_mo: 50], on_start: {M, :f, []}} =
               Options.pool(launch_options: %{slow_mo: 50}, on_start: {M, :f, []})

      # An unknown mode records nothing, as upstream's; its deprecated retry modes are
      # `:on_first_retry`, and an object without a mode is `:off`.
      assert %{trace: [mode: true] ++ _, screenshot: [mode: :on_first_retry], video: [mode: :retain_on_failure]} =
               artifacts(%{trace: true, screenshot: :on_first_retry, video: :retain_on_failure})

      assert %{trace: [mode: :on_first_retry] ++ _, video: [mode: :on_first_retry]} =
               artifacts(%{trace: :retry_with_trace, video: [mode: :retry_with_video]})

      assert %{trace: [mode: :off, snapshots: true, screenshots: true, sources: false, attachments: true]} =
               artifacts(%{trace: [sources: false]})

      assert %{video: [mode: :off, size: %{width: 320}]} = artifacts(%{video: %{size: %{width: 320}}})

      # Upstream's retry modes.
      for mode <- [:on_first_retry, :on_all_retries, :retain_on_first_failure, :retain_on_failure_and_retries] do
        assert %{trace: [mode: ^mode] ++ _, video: [mode: ^mode]} = artifacts(%{trace: mode, video: mode})
      end

      assert %{screenshot: [mode: :on_first_failure]} = artifacts(%{screenshot: :on_first_failure})
    end

    test "artifact modes are their object forms' mode, with upstream's defaults" do
      assert artifacts(%{trace: :on, screenshot: :on, video: :on}) == %{
               trace: [mode: :on, snapshots: true, screenshots: true, sources: true, attachments: true],
               screenshot: [mode: :on],
               video: [mode: :on]
             }

      assert artifacts(%{
               trace: [
                 sources: false,
                 mode: :retain_on_failure,
                 snapshots: %{dom: true, aria: false},
                 attachments: false
               ],
               screenshot: %{mode: :only_on_failure, full_page: true, omit_background: false},
               video: [mode: :on, show: %{test: %{level: "file"}}, fps: 10, size: %{width: 320, height: 240}]
             }) == %{
               trace: [
                 mode: :retain_on_failure,
                 snapshots: %{dom: true, aria: false},
                 screenshots: true,
                 sources: false,
                 attachments: false
               ],
               screenshot: [mode: :only_on_failure, full_page: true, omit_background: false],
               video: [mode: :on, size: %{width: 320, height: 240}, fps: 10, show: %{test: %{level: "file"}}]
             }
    end

    test "of a duplicated key the later wins, in the keyword lists of the values too, as JS's spread" do
      assert %{trace: [mode: :off] ++ _} = artifacts(%{trace: [mode: :on] ++ [mode: :off]})
      assert %{video: [mode: :on, fps: 2]} = artifacts(%{video: [fps: 1, mode: :on, fps: 2]})

      assert %{connect_options: [slow_mo: 2, ws_endpoint: "ws://b"]} =
               Options.pool(connect_options: [ws_endpoint: "ws://a", slow_mo: 1, ws_endpoint: "ws://b", slow_mo: 2])

      assert %{driver: [env: %{"B" => "2"}]} = Options.pool(driver: [env: %{"A" => "1"}, env: %{"B" => "2"}])
      assert %{launch_options: [slow_mo: 2]} = Options.pool(launch_options: [slow_mo: 1, slow_mo: 2])
      assert %{browser_name: :firefox} = Options.pool(browser_name: :webkit, browser_name: :firefox)
    end

    test "unknown keys of the object forms raise, their values pass as given" do
      for {option, message} <- [
            {%{trace: [mode: :on, live: true]}, ~r/unknown option trace.live, expected one of /},
            {%{video: [mode: :on, audio: true]}, ~r/unknown option video.audio, /},
            {%{screenshot: [mode: :on, path: "x.png"]}, ~r/unknown option screenshot.path, /}
          ],
          do: assert_raise(ArgumentError, message, fn -> artifacts(option) end)

      assert %{video: [mode: :on, fps: 0, show: %{test: %{level: "line"}}]} =
               artifacts(%{video: [mode: :on, fps: 0, show: %{test: %{level: "line"}}]})

      assert %{trace: [mode: :on, snapshots: 1] ++ _} = artifacts(%{trace: [mode: :on, snapshots: 1]})
    end
  end
end

defmodule Playwright.Test.ConfigTest do
  # Sets the application env.
  use ExUnit.Case, async: false
  use Playwright.Test

  import Playwright.TracedCalls

  alias Playwright.APIRequest
  alias Playwright.APIRequestContext
  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Client.Locator, as: ClientLocator
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.Runtime.Heap
  alias Playwright.Selectors
  alias Playwright.Test.BrowserPool
  alias Playwright.Test.ConfigTest.Nils
  alias Playwright.Test.Options

  # The modes of `use` options over the config's.
  defp artifacts(options),
    do: Options.artifacts(Options.config(), Options.layers(%{}, Options.use_options(Map.to_list(options)), %{}))

  setup do
    config = Application.get_env(:playwright, :test)
    on_exit(fn -> Application.put_env(:playwright, :test, config) end)
    %{config: config}
  end

  # The config's `context_options` are read at the registration, so `config` here is in effect
  # for the next test only: `context_options/0` is checked directly.
  test "the config's context_options win over Playwright Test's context defaults, converted", ctx do
    Application.put_env(
      :playwright,
      :test,
      Keyword.put(ctx.config, :context_options, locale: "de-DE", color_scheme: :dark, viewport: :null)
    )

    assert %{locale: "de-DE", colorScheme: "dark", viewport: :null, offline: false} = Options.context_options()
  end

  test "a registered test's context gets the defaults, then the config's, then its own", ctx do
    Application.put_env(:playwright, :test, Keyword.put(ctx.config, :context_options, locale: "de-DE"))
    # The registration of this test read the config before: register a fake one in a process.
    test_pid = self()
    browser = BrowserPool.browser()

    {pid, ref} =
      spawn_monitor(fn ->
        Playwright.Test.__register__(%{
          test_pid: self(),
          module: __MODULE__,
          test: :"test fake",
          file: __ENV__.file,
          line: 1
        })

        default = BrowserContext.new_page!(Browser.new_context!(browser))
        own = BrowserContext.new_page!(Browser.new_context!(browser, locale: "fr-FR"))

        send(
          test_pid,
          {:languages, Page.evaluate!(default, "navigator.language"), Page.evaluate!(own, "navigator.language")}
        )
      end)

    assert_receive {:languages, "de-DE", "fr-FR"}, 30_000
    assert_receive {:DOWN, ^ref, :process, _, _}
    Playwright.Test.__finish__(pid, 10_000)
  end

  test "a registration reads the config once" do
    test_pid = self()

    {pid, ref} =
      spawn_monitor(fn ->
        :erlang.trace(self(), true, [:call, tracer: test_pid])
        assert_receive :go
        Playwright.Test.__register__(%{test_pid: self(), module: __MODULE__, test: :"test fake", file: __ENV__.file})
        :erlang.trace(self(), false, [:call])
        send(test_pid, :registered)
      end)

    :erlang.trace_pattern({Options, :config, 0}, true, [:local])

    try do
      send(pid, :go)
      assert_receive :registered
    after
      :erlang.trace_pattern({Options, :config, 0}, false, [:local])
    end

    assert_receive {:DOWN, ^ref, :process, _, _}
    assert traced_calls(pid, {Options, :config}) == 1
    Playwright.Test.__finish__(pid, 10_000)
  end

  test "a registered test's contexts get the config's action_timeout and navigation_timeout", ctx do
    Application.put_env(:playwright, :test, ctx.config ++ [action_timeout: 300, navigation_timeout: 200])
    test_pid = self()
    browser = BrowserPool.browser()

    {pid, ref} =
      spawn_monitor(fn ->
        Playwright.Test.__register__(%{test_pid: self(), module: __MODULE__, test: :"test fake", file: __ENV__.file})
        page = BrowserContext.new_page!(Browser.new_context!(browser))
        request = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))
        request_timeout = Heap.get(Heap.get(request, :_timeoutSettings), :_defaultTimeout)
        APIRequestContext.dispose!(request)
        send(test_pid, {:errors, Page.wait_for_selector(page, "#x"), Page.wait_for_url(page, "**/x"), request_timeout})
      end)

    assert_receive {:errors, {:error, action}, {:error, navigation}, 300}, 30_000
    assert action.message =~ "page.waitForSelector: Timeout 300ms exceeded."
    assert navigation.message =~ "page.waitForURL: Timeout 200ms exceeded."
    assert_receive {:DOWN, ^ref, :process, _, _}
    Playwright.Test.__finish__(pid, 10_000)
  end

  test "options merge over the config, option lists one level deep; tags over the config", %{config: config} do
    Application.put_env(:playwright, :test, config ++ [launch_options: [headless: false, slow_mo: 1], trace: :on])

    assert %{launch_options: [headless: false, slow_mo: 50]} = Options.pool(launch_options: [slow_mo: 50])
    assert %{trace: [mode: :on] ++ _, video: [mode: :on]} = artifacts(%{video: :on})
    assert %{trace: [mode: :off] ++ _} = artifacts(%{trace: :off})
  end

  test "connect_options: the call's over the config's, nil launches", %{config: config} do
    Application.put_env(:playwright, :test, config ++ [connect_options: [ws_endpoint: "ws://config"]])
    assert %{connect_options: [ws_endpoint: "ws://config"]} = Options.pool([])

    assert %{connect_options: [slow_mo: 1, ws_endpoint: "ws://call"]} =
             Options.pool(connect_options: [ws_endpoint: "ws://call", slow_mo: 1])

    assert %{connect_options: nil} = Options.pool(connect_options: nil)
  end

  # Upstream's `undefined`: `mergeObjects` skips it in a project's `use`, a `test.use` of it
  # restores the config's.
  test "connect_options: nil of a project or a module falls back to the level under it", %{config: config} do
    Application.put_env(:playwright, :test, config ++ [connect_options: [ws_endpoint: "ws://config"]])
    config = Options.config()
    project = Options.parameters(connect_options: [ws_endpoint: "ws://project"])

    pool = fn project, use ->
      Options.pool([], Options.worker(config, Options.layers(project, %{}, %{}).project, Options.use_options(use)))
    end

    assert %{connect_options: [ws_endpoint: "ws://config"]} = pool.(Options.parameters(connect_options: nil), [])
    assert %{connect_options: [ws_endpoint: "ws://config"]} = pool.(%{}, connect_options: nil)
    assert %{connect_options: [ws_endpoint: "ws://project"]} = pool.(project, connect_options: nil)

    assert %{connect_options: [ws_endpoint: "ws://module"]} =
             pool.(project, connect_options: [ws_endpoint: "ws://module"])
  end

  test "nil of a context option, connect_options or default_browser_type falls back too", %{config: config} do
    # The config's: the default, or the config's `context_options`.
    Application.put_env(:playwright, :test, Keyword.merge(config, locale: nil, connect_options: nil))
    assert %{locale: "en-US"} = Options.context_options()
    assert %{connect_options: nil} = Options.pool([])
    refute Map.has_key?(Playwright.Test.config(), :locale)
    Application.put_env(:playwright, :test, Keyword.merge(config, locale: nil, context_options: [locale: "fr-FR"]))
    assert %{locale: "fr-FR"} = Options.context_options()

    # `default_browser_type` (a device's): the module's nil to the project's, the project's to
    # the config's, the config's to the default.
    browser = fn project, use ->
      config = Options.config()
      Options.worker(config, Options.layers(project, %{}, %{}).project, Options.use_options(use))[:browser_name]
    end

    Application.put_env(
      :playwright,
      :test,
      config |> Keyword.delete(:browser_name) |> Keyword.put(:default_browser_type, :firefox)
    )

    assert browser.(Playwright.Test.parameters(default_browser_type: :webkit), default_browser_type: nil) == :webkit
    assert browser.(Playwright.Test.parameters(default_browser_type: nil), []) == :firefox

    Application.put_env(
      :playwright,
      :test,
      config |> Keyword.delete(:browser_name) |> Keyword.put(:default_browser_type, nil)
    )

    assert browser.(%{}, default_browser_type: nil) == :chromium
  end

  # Upstream's `undefined` option override: unset at its layer, so the layer under gives it. A
  # module's or a tag's goes to the project's or the config's, past the module's own.
  test "nil of any option at any layer falls back to the layer under, then to the default", %{config: config} do
    resolve = fn project, uses, tags ->
      config = Options.config()
      use_options = uses |> Enum.map(&Options.use_options/1) |> Enum.reduce(%{}, &Options.merge(&2, &1))
      layers = Options.layers(project, use_options, Map.new(Playwright.Test.use(tags)))
      modes = Options.artifacts(config, layers)
      pool = Options.pool([], Options.worker(config, layers.project, use_options))

      Map.merge(Options.timeouts(config, layers), %{
        modes: {modes.trace[:mode], modes.screenshot[:mode], modes.video[:mode]},
        locale: Options.context_options(config, layers).locale,
        browser: {pool.browser_name, pool.launch_options}
      })
    end

    set = [
      trace: :on,
      screenshot: :on,
      video: :on,
      action_timeout: 1,
      navigation_timeout: 2,
      context_options: [locale: "es-ES"]
    ]

    worker = [browser_name: :firefox, launch_options: [slow_mo: 1]]
    nils = Enum.map(set, &{elem(&1, 0), nil})
    worker_nils = Enum.map(worker, &{elem(&1, 0), nil})

    Application.put_env(
      :playwright,
      :test,
      Keyword.merge(config,
        trace: :retain_on_failure,
        screenshot: :only_on_failure,
        video: :retain_on_failure,
        action_timeout: 10,
        navigation_timeout: 20,
        context_options: [locale: "de-DE"],
        browser_name: :webkit,
        launch_options: [slow_mo: 5]
      )
    )

    configured = %{
      modes: {:retain_on_failure, :only_on_failure, :retain_on_failure},
      action_timeout: 10,
      navigation_timeout: 20,
      locale: "de-DE",
      browser: {:webkit, [slow_mo: 5]}
    }

    # The module's `use`s compile to these.
    assert Nils.__playwright_test__(:options) ==
             Options.merge(Options.use_options(set ++ worker), Options.use_options(nils ++ worker_nils))

    # A module's `use` of nil, also after one that set them; a tag's; a project's.
    assert resolve.(%{}, [nils ++ worker_nils], []) == configured
    assert resolve.(%{}, [set ++ worker, nils ++ worker_nils], []) == configured
    assert resolve.(%{}, [set], nils) == configured
    assert resolve.(Playwright.Test.parameters(nils ++ worker_nils), [], []) == configured

    # A tag's nil goes to the project's, past the module's `use` (the worker options are the module's).
    project =
      Playwright.Test.parameters(
        trace: :on_first_retry,
        screenshot: :on_first_failure,
        video: :on_first_retry,
        action_timeout: 3,
        navigation_timeout: 4,
        context_options: [locale: "it-IT"],
        browser_name: :chromium,
        launch_options: [slow_mo: 3]
      )

    assert resolve.(project, [set ++ worker], nils) == %{
             modes: {:on_first_retry, :on_first_failure, :on_first_retry},
             action_timeout: 3,
             navigation_timeout: 4,
             locale: "it-IT",
             browser: {:firefox, [slow_mo: 1]}
           }

    # Then the defaults: without the config's, or with the config's nil.
    defaults = %{
      modes: {:off, :off, :off},
      action_timeout: :infinity,
      navigation_timeout: :infinity,
      locale: "en-US",
      browser: {:chromium, []}
    }

    Application.put_env(:playwright, :test, Keyword.drop(config, [:launch_options, :browser_name]))
    assert resolve.(%{}, [set ++ worker, nils ++ worker_nils], []) == defaults
    assert resolve.(%{}, [set], nils) == defaults
    Application.put_env(:playwright, :test, Keyword.merge(config, nils ++ worker_nils))
    assert resolve.(%{}, [nils ++ worker_nils], nils) == defaults
  end

  # Playwright Test's `testIdAttribute`: the client's value is the VM's, so this module is not
  # async, and resets it.
  test "test_id_attribute: each new pooled driver gets it, as the client does", %{config: config} do
    Application.put_env(:playwright, :test, config ++ [test_id_attribute: "data-pw"])
    browser = BrowserPool.browser(driver: [env: [{"PW_TEST_ID_ATTRIBUTE_TEST", "1"}]])
    selectors = Playwright.selectors(BrowserPool.playwright(browser))
    on_exit(fn -> Selectors.set_test_id_attribute(selectors, "data-testid") end)

    assert ClientLocator.test_id_attribute_name() == "data-pw"
    page = BrowserContext.new_page!(Browser.new_context!(browser))
    Page.set_content!(page, ~s(<div data-pw="a">A</div><div data-testid="a">B</div>))
    assert Locator.text_content!(Page.get_by_test_id(page, "a")) == "A"
  end

  test "the defaults", %{config: config} do
    Application.delete_env(:playwright, :test)

    assert %{browser_name: :chromium, launch_options: [], connect_options: nil, driver: [], on_start: nil} =
             Options.pool([])

    assert %{
             trace: [mode: :off, snapshots: true, screenshots: true, sources: true, attachments: true],
             screenshot: [mode: :off],
             video: [mode: :off]
           } = artifacts(%{})

    assert Options.context_options() == Options.context_defaults()
    assert Options.timeouts() == %{action_timeout: :infinity, navigation_timeout: :infinity}
    assert Options.output_dir() == "test-results"
    assert Options.preserve_output() == :always
    assert Options.workers() == max(div(System.schedulers_online(), 2), 1)
    assert Options.test_id_attribute() == "data-testid"
    Application.put_env(:playwright, :test, config)
  end

  test "config/0: the resolved config, also outside a test", %{config: config} do
    expect = Application.get_env(:playwright, :expect)
    on_exit(fn -> Application.put_env(:playwright, :expect, expect) end)
    Application.delete_env(:playwright, :test)
    Application.delete_env(:playwright, :expect)
    test_pid = self()
    spawn(fn -> send(test_pid, {:config, Playwright.Test.config()}) end)
    assert_receive {:config, resolved}

    assert resolved == %{
             browser_name: :chromium,
             default_browser_type: nil,
             launch_options: [],
             connect_options: nil,
             driver: [],
             on_start: nil,
             trace: [mode: :off, snapshots: true, screenshots: true, sources: true, attachments: true],
             screenshot: [mode: :off],
             video: [mode: :off],
             context_options: [],
             action_timeout: :infinity,
             navigation_timeout: :infinity,
             output_dir: "test-results",
             preserve_output: :always,
             workers: max(div(System.schedulers_online(), 2), 1),
             snapshot_dir: nil,
             snapshot_path_template: nil,
             test_id_attribute: "data-testid",
             report_slow_tests: [max: 5, threshold: 300_000],
             expect: %{timeout: 5000}
           }

    Application.put_env(:playwright, :test, config ++ [action_timeout: 0, context_options: [locale: "de-DE"]])
    Application.put_env(:playwright, :expect, timeout: 0)

    assert %{action_timeout: 0, context_options: [locale: "de-DE"], expect: %{timeout: 0}} =
             Playwright.Test.config()

    Application.put_env(:playwright, :test, config ++ [context_options: [lokale: "x"]])
    assert_raise ArgumentError, fn -> Playwright.Test.config() end
    Application.put_env(:playwright, :test, Keyword.put(config, :workers, 0))
    assert_raise ArgumentError, ~r/invalid value 0 for workers, /, fn -> Playwright.Test.config() end
  end

  test "a bad config raises", %{config: config} do
    Application.put_env(:playwright, :test, config ++ [tracing: :on])

    assert_raise ArgumentError,
                 ~r/config :playwright, :test: unknown key tracing, expected one of browser_name, /,
                 fn -> artifacts(%{}) end

    # At the application's start, before anything reads it.
    assert_raise ArgumentError, ~r/unknown key tracing, /, fn ->
      Playwright.Application.start(:normal, [])
    end

    Application.put_env(:playwright, :test, config ++ [context_options: [lokale: "x"]])
    assert_raise ArgumentError, fn -> Playwright.Application.start(:normal, []) end

    # error-context.md has no switch, as upstream.
    Application.put_env(:playwright, :test, config ++ [error_context: true])
    assert_raise ArgumentError, ~r/unknown key error_context, /, fn -> Options.pool([]) end

    # Upstream's `testIdAttribute: ''` sets none (`if (testIdAttribute)`).
    Application.put_env(:playwright, :test, config ++ [test_id_attribute: ""])
    assert Options.test_id_attribute() == nil

    Application.put_env(:playwright, :test, config ++ [preserve_output: :on_failure])
    assert_raise ArgumentError, ~r/invalid value :on_failure for preserve_output, /, fn -> Options.preserve_output() end

    Application.put_env(:playwright, :test, config ++ [context_options: [lokale: "x"]])
    assert_raise ArgumentError, fn -> Options.context_options() end

    Application.put_env(:playwright, :test, config ++ [action_timeout: 0, navigation_timeout: 5000])
    assert Options.timeouts() == %{action_timeout: 0, navigation_timeout: 5000}
  end
end

defmodule Playwright.Test.ConfigTest.Nils do
  # No tests: a `use` of nil for every option, after one that set them.
  use ExUnit.Case, async: true

  use Playwright.Test,
    trace: :on,
    screenshot: :on,
    video: :on,
    action_timeout: 1,
    navigation_timeout: 2,
    context_options: [locale: "es-ES"],
    browser_name: :firefox,
    launch_options: [slow_mo: 1]

  use Playwright.Test,
    trace: nil,
    screenshot: nil,
    video: nil,
    action_timeout: nil,
    navigation_timeout: nil,
    context_options: nil,
    browser_name: nil,
    launch_options: nil
end
