defmodule PlaywrightEx.Test.OptionsTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Options

  describe "validation" do
    test "unknown options raise before anything starts" do
      assert_raise ArgumentError, ~r/unknown options \[:headless\]/, fn -> BrowserPool.browser(headless: true) end
      assert_raise ArgumentError, ~r/unknown driver options \[:name\]/, fn -> Options.pool(driver: [name: Foo]) end
    end

    test "bad values raise" do
      assert_raise ArgumentError, ~r/invalid browser_name: :chrome/, fn -> Options.pool(browser_name: :chrome) end

      assert_raise ArgumentError, ~r/invalid trace: :retry_with_trace, expected one of/, fn ->
        Options.artifacts(%{trace: :retry_with_trace})
      end

      assert_raise ArgumentError, ~r/invalid screenshot: :on_first_retry/, fn ->
        Options.artifacts(%{screenshot: :on_first_retry})
      end

      assert_raise ArgumentError, ~r/invalid screenshot: :retain_on_failure/, fn ->
        Options.artifacts(%{screenshot: :retain_on_failure})
      end

      assert_raise ArgumentError, ~r/invalid video: :only_on_failure/, fn ->
        Options.artifacts(%{video: :only_on_failure})
      end

      assert_raise ArgumentError, ~r/invalid on_start/, fn -> Options.pool(on_start: fn -> :ok end) end
      assert_raise ArgumentError, ~r/invalid launch_options: "x"/, fn -> Options.pool(launch_options: "x") end
      assert_raise ArgumentError, ~r/expected a keyword list/, fn -> Options.pool([:driver]) end
    end

    test "connect options: BrowserType.connect's and ws_endpoint, which is required" do
      assert %{connect_options: [headers: %{"a" => "b"}, slow_mo: 1, ws_endpoint: "ws://x"]} =
               Options.pool(connect_options: %{ws_endpoint: "ws://x", slow_mo: 1, headers: %{"a" => "b"}})

      assert %{connect_options: nil} = Options.pool(connect_options: nil)

      assert_raise ArgumentError, ~r/unknown connect options \[:launch_options\]/, fn ->
        Options.pool(connect_options: [ws_endpoint: "ws://x", launch_options: []])
      end

      assert_raise ArgumentError, ~r/connect options need :ws_endpoint/, fn ->
        Options.pool(connect_options: [timeout: 1])
      end
    end

    test "options are as given, keyword lists or maps; tags true and false are :on and :off" do
      assert %{launch_options: [slow_mo: 50], on_start: {M, :f, []}} =
               Options.pool(launch_options: %{slow_mo: 50}, on_start: {M, :f, []})

      assert %{trace: [mode: :on] ++ _, screenshot: [mode: :off], video: [mode: :retain_on_failure]} =
               Options.artifacts(%{trace: true, screenshot: false, video: :retain_on_failure})

      # Upstream's retry modes.
      for mode <- [:on_first_retry, :on_all_retries, :retain_on_first_failure, :retain_on_failure_and_retries] do
        assert %{trace: [mode: ^mode] ++ _, video: [mode: ^mode]} = Options.artifacts(%{trace: mode, video: mode})
      end

      assert %{screenshot: [mode: :on_first_failure]} = Options.artifacts(%{screenshot: :on_first_failure})
    end

    test "artifact modes are their object forms' mode, with upstream's defaults" do
      assert Options.artifacts(%{trace: :on, screenshot: :on, video: :on}) == %{
               trace: [mode: :on, snapshots: true, screenshots: true, sources: true, attachments: true],
               screenshot: [mode: :on],
               video: [mode: :on]
             }

      assert Options.artifacts(%{
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

    test "unknown keys and bad values of the object forms raise" do
      for {option, message} <- [
            {%{trace: [mode: :on, live: true]}, ~r/unknown trace options \[:live\], expected one of/},
            {%{trace: [mode: :on, attachments: 1]}, ~r/invalid trace attachments: 1/},
            {%{video: [mode: :on, audio: true]}, ~r/unknown video options \[:audio\]/},
            {%{video: [mode: :on, fps: 0]}, ~r/invalid video fps: 0/},
            {%{video: [mode: :on, show: %{test: %{level: "line"}}]}, ~r/invalid video show: /},
            {%{video: [mode: :on, show: %{actions: %{color: "red"}}]}, ~r/invalid video show: /},
            {%{screenshot: [mode: :on, path: "x.png"]}, ~r/unknown screenshot options \[:path\]/},
            {%{trace: [sources: false]}, ~r/trace options need :mode/},
            {%{video: %{size: %{width: 320, height: 240}}}, ~r/video options need :mode/},
            {%{trace: [mode: :retry_with_trace]}, ~r/invalid trace: :retry_with_trace, expected one of/},
            {%{trace: [mode: :on, snapshots: 1]}, ~r/invalid trace snapshots: 1/},
            {%{trace: [mode: :on, snapshots: %{dom: true, network: true}]}, ~r/invalid trace snapshots: %{/},
            {%{trace: [mode: :on, sources: nil]}, ~r/invalid trace sources: nil/},
            {%{screenshot: [mode: :on, full_page: "yes"]}, ~r/invalid screenshot full_page: "yes"/},
            {%{video: [mode: :on, size: [width: 320, height: 240]]}, ~r/invalid video size: \[/},
            {%{video: [mode: :on, size: %{width: 320}]}, ~r/invalid video size: %{width: 320}/},
            {%{trace: "on"}, ~r/invalid trace: "on"/},
            {%{trace: nil}, ~r/invalid trace: nil/}
          ],
          do: assert_raise(ArgumentError, message, fn -> Options.artifacts(option) end)
    end
  end
end

defmodule PlaywrightEx.Test.ConfigTest do
  # Sets the application env.
  use ExUnit.Case, async: false
  use PlaywrightEx.Test

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Client.Locator, as: ClientLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Selectors
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Options

  setup do
    config = Application.get_env(:playwright_ex, :test)
    on_exit(fn -> Application.put_env(:playwright_ex, :test, config) end)
    %{config: config}
  end

  # The config's `context_options` are read at the registration, so `config` here is in effect
  # for the next test only: `context_options/0` is checked directly.
  test "the config's context_options win over Playwright Test's context defaults, converted", ctx do
    Application.put_env(
      :playwright_ex,
      :test,
      Keyword.put(ctx.config, :context_options, locale: "de-DE", color_scheme: :dark, viewport: :null)
    )

    assert %{locale: "de-DE", colorScheme: "dark", viewport: :null, offline: false} = Options.context_options()
  end

  test "a registered test's context gets the defaults, then the config's, then its own", ctx do
    Application.put_env(:playwright_ex, :test, Keyword.put(ctx.config, :context_options, locale: "de-DE"))
    # The registration of this test read the config before: register a fake one in a process.
    test_pid = self()
    browser = BrowserPool.browser()

    {pid, ref} =
      spawn_monitor(fn ->
        PlaywrightEx.Test.__register__(%{
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
    PlaywrightEx.Test.__finish__(pid, 10_000)
  end

  test "a registration reads the config once" do
    test_pid = self()

    {pid, ref} =
      spawn_monitor(fn ->
        # `call_count` counts the calls of the processes with the `call` flag: this one.
        :erlang.trace(self(), true, [:call, tracer: test_pid])
        assert_receive :go
        PlaywrightEx.Test.__register__(%{test_pid: self(), module: __MODULE__, test: :"test fake", file: __ENV__.file})
        send(test_pid, {:count, :erlang.trace_info({Options, :config, 0}, :call_count)})
      end)

    :erlang.trace_pattern({Options, :config, 0}, true, [:call_count])

    try do
      send(pid, :go)
      assert_receive {:count, {:call_count, 1}}
    after
      :erlang.trace_pattern({Options, :config, 0}, false, [:call_count])
    end

    assert_receive {:DOWN, ^ref, :process, _, _}
    PlaywrightEx.Test.__finish__(pid, 10_000)
  end

  test "a registered test's contexts get the config's action_timeout and navigation_timeout", ctx do
    Application.put_env(:playwright_ex, :test, ctx.config ++ [action_timeout: 300, navigation_timeout: 200])
    test_pid = self()
    browser = BrowserPool.browser()

    {pid, ref} =
      spawn_monitor(fn ->
        PlaywrightEx.Test.__register__(%{test_pid: self(), module: __MODULE__, test: :"test fake", file: __ENV__.file})
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
    PlaywrightEx.Test.__finish__(pid, 10_000)
  end

  test "options merge over the config, option lists one level deep; tags over the config", %{config: config} do
    Application.put_env(:playwright_ex, :test, config ++ [launch_options: [headless: false, slow_mo: 1], trace: :on])

    assert %{launch_options: [headless: false, slow_mo: 50]} = Options.pool(launch_options: [slow_mo: 50])
    assert %{trace: [mode: :on] ++ _, video: [mode: :on]} = Options.artifacts(%{video: :on})
    assert %{trace: [mode: :off] ++ _} = Options.artifacts(%{trace: false})
  end

  test "connect_options: the call's over the config's, nil launches", %{config: config} do
    Application.put_env(:playwright_ex, :test, config ++ [connect_options: [ws_endpoint: "ws://config"]])
    assert %{connect_options: [ws_endpoint: "ws://config"]} = Options.pool([])

    assert %{connect_options: [slow_mo: 1, ws_endpoint: "ws://call"]} =
             Options.pool(connect_options: [ws_endpoint: "ws://call", slow_mo: 1])

    assert %{connect_options: nil} = Options.pool(connect_options: nil)
  end

  # Playwright Test's `testIdAttribute`: the client's value is the VM's, so this module is not
  # async, and resets it.
  test "test_id_attribute: each new pooled driver gets it, as the client does", %{config: config} do
    Application.put_env(:playwright_ex, :test, config ++ [test_id_attribute: "data-pw"])
    browser = BrowserPool.browser(driver: [env: [{"PW_TEST_ID_ATTRIBUTE_TEST", "1"}]])
    selectors = Playwright.selectors(BrowserPool.playwright(browser))
    on_exit(fn -> Selectors.set_test_id_attribute(selectors, "data-testid") end)

    assert ClientLocator.test_id_attribute_name() == "data-pw"
    page = BrowserContext.new_page!(Browser.new_context!(browser))
    Page.set_content!(page, ~s(<div data-pw="a">A</div><div data-testid="a">B</div>))
    assert Locator.text_content!(Page.get_by_test_id(page, "a")) == "A"
  end

  test "the defaults", %{config: config} do
    Application.delete_env(:playwright_ex, :test)

    assert %{browser_name: :chromium, launch_options: [], connect_options: nil, driver: [], on_start: nil} =
             Options.pool([])

    assert %{
             trace: [mode: :off, snapshots: true, screenshots: true, sources: true, attachments: true],
             screenshot: [mode: :off],
             video: [mode: :off]
           } = Options.artifacts(%{})

    assert Options.context_options() == Options.context_defaults()
    assert Options.timeouts() == %{action_timeout: :infinity, navigation_timeout: :infinity}
    assert Options.output_dir() == "test-results"
    assert Options.preserve_output() == :always
    assert Options.workers() == max(div(System.schedulers_online(), 2), 1)
    assert Options.test_id_attribute() == "data-testid"
    Application.put_env(:playwright_ex, :test, config)
  end

  test "config/0: the resolved config, also outside a test", %{config: config} do
    expect = Application.get_env(:playwright_ex, :expect)
    on_exit(fn -> Application.put_env(:playwright_ex, :expect, expect) end)
    Application.delete_env(:playwright_ex, :test)
    Application.delete_env(:playwright_ex, :expect)
    test_pid = self()
    spawn(fn -> send(test_pid, {:config, PlaywrightEx.Test.config()}) end)
    assert_receive {:config, resolved}

    assert resolved == %{
             browser_name: :chromium,
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
             expect: %{timeout: 5000}
           }

    Application.put_env(:playwright_ex, :test, config ++ [action_timeout: 0, context_options: [locale: "de-DE"]])
    Application.put_env(:playwright_ex, :expect, timeout: 0)

    assert %{action_timeout: 0, context_options: [locale: "de-DE"], expect: %{timeout: 0}} =
             PlaywrightEx.Test.config()

    Application.put_env(:playwright_ex, :test, config ++ [context_options: [lokale: "x"]])
    assert_raise ArgumentError, fn -> PlaywrightEx.Test.config() end
    Application.put_env(:playwright_ex, :test, Keyword.put(config, :workers, 0))
    assert_raise ArgumentError, ~r/invalid workers: 0/, fn -> PlaywrightEx.Test.config() end
  end

  test "a bad config raises", %{config: config} do
    Application.put_env(:playwright_ex, :test, config ++ [tracing: :on])

    assert_raise ArgumentError, ~r/unknown keys \[:tracing\] in config :playwright_ex, :test/, fn ->
      Options.artifacts(%{})
    end

    # error-context.md has no switch, as upstream.
    Application.put_env(:playwright_ex, :test, config ++ [error_context: true])
    assert_raise ArgumentError, ~r/unknown keys \[:error_context\]/, fn -> Options.pool([]) end

    Application.put_env(:playwright_ex, :test, config ++ [test_id_attribute: ""])
    assert_raise ArgumentError, ~r/invalid test_id_attribute: ""/, fn -> Options.test_id_attribute() end

    Application.put_env(:playwright_ex, :test, config ++ [preserve_output: :on_failure])
    assert_raise ArgumentError, ~r/invalid preserve_output: :on_failure/, fn -> Options.preserve_output() end

    Application.put_env(:playwright_ex, :test, config ++ [trace: :sometimes])
    assert_raise ArgumentError, ~r/invalid trace: :sometimes/, fn -> Options.artifacts(%{}) end

    Application.put_env(:playwright_ex, :test, config ++ [context_options: [lokale: "x"]])
    assert_raise ArgumentError, fn -> Options.context_options() end

    for value <- [-1, 1.5, nil, "1000"] do
      Application.put_env(:playwright_ex, :test, config ++ [action_timeout: value])

      assert_raise ArgumentError, ~r/invalid action_timeout: #{Regex.escape(inspect(value))}/, fn ->
        Options.timeouts()
      end
    end

    Application.put_env(:playwright_ex, :test, config ++ [navigation_timeout: :none])
    assert_raise ArgumentError, ~r/invalid navigation_timeout: :none/, fn -> Options.timeouts() end
    Application.put_env(:playwright_ex, :test, config ++ [action_timeout: 0, navigation_timeout: 5000])
    assert Options.timeouts() == %{action_timeout: 0, navigation_timeout: 5000}
  end
end
