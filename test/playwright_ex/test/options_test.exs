defmodule PlaywrightEx.Test.OptionsTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Recorder

  describe "validation" do
    test "unknown options raise before anything starts" do
      assert_raise ArgumentError, ~r/unknown options \[:headless\]/, fn -> BrowserPool.shared(headless: true) end
      assert_raise ArgumentError, ~r/unknown options \[:isolate\]/, fn -> BrowserPool.exclusive(isolate: true) end
      assert_raise ArgumentError, ~r/unknown driver options \[:name\]/, fn -> Options.pool(driver: [name: Foo]) end
    end

    test "bad values raise" do
      assert_raise ArgumentError, ~r/invalid browser_name: :chrome/, fn -> Options.pool(browser_name: :chrome) end

      assert_raise ArgumentError, ~r/invalid trace: :on_first_retry, expected one of/, fn ->
        Options.artifacts(%{trace: :on_first_retry})
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
    end

    test "artifact modes are their object forms' mode, with upstream's defaults" do
      assert Options.artifacts(%{trace: :on, screenshot: :on, video: :on}) == %{
               trace: [mode: :on, snapshots: true, screenshots: true, sources: true],
               screenshot: [mode: :on],
               video: [mode: :on]
             }

      assert Options.artifacts(%{
               trace: [sources: false, mode: :retain_on_failure, snapshots: %{dom: true, aria: false}],
               screenshot: %{mode: :only_on_failure, full_page: true, omit_background: false},
               video: [mode: :on, size: %{width: 320, height: 240}]
             }) == %{
               trace: [
                 mode: :retain_on_failure,
                 snapshots: %{dom: true, aria: false},
                 screenshots: true,
                 sources: false
               ],
               screenshot: [mode: :only_on_failure, full_page: true, omit_background: false],
               video: [mode: :on, size: %{width: 320, height: 240}]
             }
    end

    test "unknown keys and bad values of the object forms raise" do
      for {option, message} <- [
            {%{trace: [mode: :on, attachments: false]}, ~r/unknown trace options \[:attachments\], expected one of/},
            {%{video: [mode: :on, fps: 30]}, ~r/unknown video options \[:fps\]/},
            {%{screenshot: [mode: :on, path: "x.png"]}, ~r/unknown screenshot options \[:path\]/},
            {%{trace: [sources: false]}, ~r/trace options need :mode/},
            {%{video: %{size: %{width: 320, height: 240}}}, ~r/video options need :mode/},
            {%{trace: [mode: :on_first_retry]}, ~r/invalid trace: :on_first_retry, expected one of/},
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

  describe "parameters" do
    defmodule Weird do
      def __ex_unit__(:config), do: [parameterize: [%{n: 1}]]
    end

    defmodule Parameterized do
      def __ex_unit__(:config), do: %{parameterize: [%{n: 1, m: 1}, %{n: 2, m: 1}]}
    end

    test "are the parameter map whose values the context has" do
      assert Recorder.parameters(Parameterized, %{n: 2, m: 1, test: :t}) == %{n: 2, m: 1}
      assert Recorder.parameters(Parameterized, %{n: 3, m: 1}) == %{}
      assert Recorder.parameters(__MODULE__, %{n: 1}) == %{}
    end

    test "are %{} when ExUnit's internal config is missing or of another shape" do
      assert Recorder.parameters(M, %{n: 1}) == %{}
      assert Recorder.parameters(Weird, %{n: 1}) == %{}
    end
  end

  describe "output dirs" do
    defp output_dir(file, name, module \\ MyApp.CheckoutTest, parameters \\ %{}) do
      dir = Recorder.output_dir("out", file, name, module, parameters)
      assert [_, name] = Regex.run(~r"^out/(.*)-[0-9a-f]{5}$", dir)
      name
    end

    test "as upstream's testInfo.outputDir: the file relative to test/, then the sanitized test name" do
      file = Path.join(File.cwd!(), "test/my_app/checkout_test.exs")
      assert output_dir(file, "pays by card") == "my_app-checkout-pays-by-card"
      assert output_dir(file, "cart: add_item/2 (EUR)") == "my_app-checkout-cart-add-item-2-EUR-"
    end

    test "a file outside test/ is relative to the working directory" do
      assert output_dir(Path.join(File.cwd!(), "e2e/flow_test.exs"), "a") == "e2e-flow-a"
    end

    test "long names are trimmed to 60 characters with a hash, as trimLongString" do
      file = Path.join(File.cwd!(), "test/my_app/checkout_test.exs")
      name = output_dir(file, String.duplicate("very long name ", 6))
      assert String.length(name) == 60
      assert name =~ ~r/^my_app-checkout-very-long--[0-9a-f]{5}-y-long-name-very-long-name-$/
    end

    test "the suffix tells modules of one file and parameters apart" do
      file = Path.join(File.cwd!(), "test/my_app/checkout_test.exs")

      dirs =
        for {module, parameters} <- [
              {MyApp.ATest, %{}},
              {MyApp.BTest, %{}},
              {MyApp.ATest, %{n: 1}},
              {MyApp.ATest, %{n: 2}}
            ],
            do: Recorder.output_dir("out", file, "pays", module, parameters)

      assert length(Enum.uniq(dirs)) == 4
      assert Recorder.output_dir("out", file, "pays", MyApp.ATest, %{}) == hd(dirs)
    end

    test "the test name is without its macro's prefix, test_type's" do
      assert Recorder.test_name(%{test: :"test pays", test_type: :test}) == "pays"
      assert Recorder.test_name(%{test: :"feature pays", test_type: :feature}) == "pays"
      assert Recorder.test_name(%{test: :"test pays"}) == "pays"
    end

    test "sanitizeForFilePath keeps letters, digits, dashes and non-ASCII" do
      assert Recorder.sanitize_for_file_path("a_b.c/d e:f-ü") == "a-b-c-d-e-f-ü"
    end
  end

  describe "trace merge (mergeTraceFiles)" do
    @describetag :tmp_dir

    test "prefixes each chunk's trace files with its index and keeps resources once", %{tmp_dir: dir} do
      chunk = fn name, entries ->
        path = Path.join(dir, name)
        {:ok, _} = :zip.create(String.to_charlist(path), for({n, d} <- entries, do: {String.to_charlist(n), d}))
        path
      end

      a = chunk.("a.zip", [{"trace.trace", "a"}, {"trace.network", "an"}, {"resources/x", "x"}])
      b = chunk.("b.zip", [{"trace.trace", "b"}, {"trace.network", "bn"}, {"resources/x", "x"}, {"resources/y", "y"}])
      merged = Path.join(dir, "out/trace.zip")

      assert Recorder.merge_traces(merged, [a, b, Path.join(dir, "missing.zip")]) == :ok
      {:ok, files} = :zip.unzip(String.to_charlist(merged), [:memory])
      files = Map.new(files, fn {name, data} -> {to_string(name), data} end)

      assert files == %{
               "0-trace.trace" => "a",
               "0-trace.network" => "an",
               "1-trace.trace" => "b",
               "1-trace.network" => "bn",
               "resources/x" => "x",
               "resources/y" => "y"
             }

      refute File.exists?(a) or File.exists?(b)
    end

    test "a single chunk keeps its names, none gives none", %{tmp_dir: dir} do
      path = Path.join(dir, "a.zip")
      {:ok, _} = :zip.create(String.to_charlist(path), [{~c"trace.trace", "a"}, {~c"resources/x", "x"}])
      assert Recorder.merge_traces(Path.join(dir, "t/trace.zip"), [path]) == :ok
      {:ok, files} = :zip.unzip(String.to_charlist(Path.join(dir, "t/trace.zip")), [:memory])
      assert Enum.sort(files) == [{~c"resources/x", "x"}, {~c"trace.trace", "a"}]
      assert Recorder.merge_traces(Path.join(dir, "u/trace.zip"), [path]) == :none
    end
  end
end

defmodule PlaywrightEx.Test.ConfigTest do
  # Sets the application env.
  use ExUnit.Case, async: false
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
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

    {pid, ref} =
      spawn_monitor(fn ->
        PlaywrightEx.Test.__register__(%{
          test_pid: self(),
          module: __MODULE__,
          test: :"test fake",
          file: __ENV__.file,
          line: 1
        })

        browser = BrowserPool.shared()
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

  test "options merge over the config, option lists one level deep; tags over the config", %{config: config} do
    Application.put_env(:playwright_ex, :test, config ++ [launch_options: [headless: false, slow_mo: 1], trace: :on])

    assert %{launch_options: [headless: false, slow_mo: 50]} = Options.pool(launch_options: [slow_mo: 50])
    assert %{trace: [mode: :on] ++ _, video: [mode: :on]} = Options.artifacts(%{video: :on})
    assert %{trace: [mode: :off] ++ _} = Options.artifacts(%{trace: false})
  end

  test "PW_TEST_CONNECT_* are the connect_options default, under the config and the call", %{config: config} do
    env = ~w(PW_TEST_CONNECT_WS_ENDPOINT PW_TEST_CONNECT_HEADERS PW_TEST_CONNECT_EXPOSE_NETWORK)
    saved = Map.new(env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn {name, value} -> if value, do: System.put_env(name, value), else: System.delete_env(name) end)
    end)

    System.put_env("PW_TEST_CONNECT_WS_ENDPOINT", "ws://env")
    System.delete_env("PW_TEST_CONNECT_HEADERS")
    System.delete_env("PW_TEST_CONNECT_EXPOSE_NETWORK")
    assert %{connect_options: [ws_endpoint: "ws://env"]} = Options.pool([])

    System.put_env("PW_TEST_CONNECT_HEADERS", ~s({"x-token": "t"}))
    System.put_env("PW_TEST_CONNECT_EXPOSE_NETWORK", "<loopback>")

    assert %{connect_options: [expose_network: "<loopback>", headers: %{"x-token" => "t"}, ws_endpoint: "ws://env"]} =
             Options.pool([])

    assert %{connect_options: nil} = Options.pool(connect_options: nil)
    assert %{connect_options: [ws_endpoint: "ws://call"]} = Options.pool(connect_options: [ws_endpoint: "ws://call"])
    Application.put_env(:playwright_ex, :test, config ++ [connect_options: [ws_endpoint: "ws://config"]])
    assert %{connect_options: [ws_endpoint: "ws://config"]} = Options.pool([])
    Application.put_env(:playwright_ex, :test, config ++ [connect_options: nil])
    assert %{connect_options: nil} = Options.pool([])
  end

  test "the defaults", %{config: config} do
    Application.delete_env(:playwright_ex, :test)

    assert %{browser_name: :chromium, launch_options: [], connect_options: nil, driver: [], on_start: nil} =
             Options.pool([])

    assert %{
             trace: [mode: :off, snapshots: true, screenshots: true, sources: true],
             screenshot: [mode: :off],
             video: [mode: :off]
           } = Options.artifacts(%{})

    assert Options.context_options() == Options.context_defaults()
    assert Options.output_dir() == "test-results"
    assert Options.workers() == max(div(System.schedulers_online(), 2), 1)
    Application.put_env(:playwright_ex, :test, config)
  end

  test "a bad config raises", %{config: config} do
    Application.put_env(:playwright_ex, :test, config ++ [tracing: :on])

    assert_raise ArgumentError, ~r/unknown keys \[:tracing\] in config :playwright_ex, :test/, fn ->
      Options.artifacts(%{})
    end

    # `isolate` is gone, and error-context.md has no switch, as upstream.
    for key <- [:isolate, :error_context] do
      Application.put_env(:playwright_ex, :test, config ++ [{key, true}])
      assert_raise ArgumentError, ~r/unknown keys \[#{inspect(key)}\]/, fn -> Options.pool([]) end
    end

    Application.put_env(:playwright_ex, :test, config ++ [trace: :sometimes])
    assert_raise ArgumentError, ~r/invalid trace: :sometimes/, fn -> Options.artifacts(%{}) end

    Application.put_env(:playwright_ex, :test, config ++ [context_options: [lokale: "x"]])
    assert_raise ArgumentError, fn -> Options.context_options() end
  end
end
