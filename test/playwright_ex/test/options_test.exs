defmodule PlaywrightEx.Test.OptionsTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Recorder

  describe "validation" do
    test "unknown options raise before anything starts" do
      assert_raise ArgumentError, ~r/unknown options \[:headless\]/, fn -> PlaywrightEx.Test.browser(headless: true) end

      assert_raise ArgumentError, ~r/unknown options \[:locale\]/, fn ->
        PlaywrightEx.Test.new_context(%{}, locale: "de")
      end

      assert_raise ArgumentError, ~r/unknown options/, fn -> Options.artifacts(tracing: :on) end
      assert_raise ArgumentError, ~r/unknown driver options \[:name\]/, fn -> Options.browser(driver: [name: Foo]) end
    end

    test "bad values raise" do
      assert_raise ArgumentError, ~r/invalid browser_name: :chrome/, fn -> Options.browser(browser_name: :chrome) end

      assert_raise ArgumentError, ~r/invalid trace: :on_first_retry, expected one of/, fn ->
        Options.artifacts(trace: :on_first_retry)
      end

      assert_raise ArgumentError, ~r/invalid screenshot: :retain_on_failure/, fn ->
        Options.artifacts(screenshot: :retain_on_failure)
      end

      assert_raise ArgumentError, ~r/invalid video: :only_on_failure/, fn ->
        Options.artifacts(video: :only_on_failure)
      end

      assert_raise ArgumentError, ~r/invalid isolate: 1/, fn -> Options.browser(isolate: 1) end
      assert_raise ArgumentError, ~r/invalid on_start/, fn -> Options.browser(on_start: fn -> :ok end) end
      assert_raise ArgumentError, ~r/invalid launch_options: "x"/, fn -> Options.browser(launch_options: "x") end
      assert_raise ArgumentError, ~r/expected a keyword list/, fn -> Options.browser([:isolate]) end
    end

    test "options are as given, keyword lists or maps" do
      assert %{launch_options: [slow_mo: 50], on_start: {M, :f, []}, isolate: false} =
               Options.browser(launch_options: %{slow_mo: 50}, on_start: {M, :f, []})

      assert %{trace: :on, screenshot: :off, video: :retain_on_failure} =
               Options.artifacts(trace: :on, video: :retain_on_failure)

      assert %{context_options: [locale: "de-DE"]} = Options.context(context_options: [locale: "de-DE"])
    end

    test "isolate needs the context map of a module with use PlaywrightEx.Test" do
      message = assert_raise(ArgumentError, fn -> PlaywrightEx.Test.browser(isolate: true) end).message
      assert message =~ "browser(context, isolate: true) needs a test module with `use PlaywrightEx.Test`"
      assert message =~ "add it after `use ExUnit.Case`"
    end

    test "fragments given the context map of a module without use PlaywrightEx.Test say to add it", ctx do
      for {what, fun} <- [
            {"browser/1", &PlaywrightEx.Test.browser/1},
            {"record_artifacts/2", &PlaywrightEx.Test.record_artifacts/1}
          ],
          do:
            assert_raise(
              ArgumentError,
              ~r/^#{Regex.escape(what)} needs a test module with `use PlaywrightEx.Test`/,
              fn -> fun.(ctx) end
            )

      assert_raise ArgumentError, ~r/^new_context\/2 needs a test module/, fn ->
        PlaywrightEx.Test.new_context(Map.put(ctx, :browser, :a_browser))
      end
    end

    test "fragments need their keys" do
      assert_raise ArgumentError, ~r/expected :browser in the context map/, fn -> PlaywrightEx.Test.new_context(%{}) end
      assert_raise ArgumentError, ~r/expected :context in the context map/, fn -> PlaywrightEx.Test.new_page(%{}) end

      assert_raise ArgumentError, ~r/expected :file/, fn ->
        PlaywrightEx.Test.record_artifacts(%{module: M, test: :t})
      end
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

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Recorder

  setup do
    config = Application.get_env(:playwright_ex, :test)
    on_exit(fn -> Application.put_env(:playwright_ex, :test, config) end)
    %{config: config}
  end

  test "new_context starts a recording with the config when the test hasn't", ctx do
    dir = Recorder.output_dir(ctx)

    on_exit(fn ->
      assert File.ls!(dir) == ["test-finished-1.png"]
      File.rm_rf!(dir)
    end)

    Application.put_env(:playwright_ex, :test, Keyword.put(ctx.config, :screenshot, :on))
    %{browser: browser} = PlaywrightEx.Test.browser(ctx)
    %{context: context} = PlaywrightEx.Test.new_context(Map.put(ctx, :browser, browser))
    Page.set_content!(BrowserContext.new_page!(context), "<h1>Defaults</h1>")
  end

  test "options merge over the config, option lists one level deep", %{config: config} do
    Application.put_env(
      :playwright_ex,
      :test,
      config ++ [launch_options: [headless: false, slow_mo: 1], trace: :on, context_options: %{locale: "de-DE"}]
    )

    assert %{launch_options: [headless: false, slow_mo: 50]} = Options.browser(launch_options: [slow_mo: 50])
    assert %{trace: :on, video: :on} = Options.artifacts(video: :on)
    assert %{context_options: [locale: "de-DE", base_url: "/"]} = Options.context(context_options: [base_url: "/"])
  end

  test "the defaults", %{config: config} do
    Application.delete_env(:playwright_ex, :test)
    assert %{browser_name: :chromium, isolate: false, on_start: nil} = Options.browser([])
    assert %{trace: :off, screenshot: :off, video: :off} = Options.artifacts([])
    assert Options.output_dir() == "test-results"
    assert Options.max_isolated() == max(div(System.schedulers_online(), 2), 1)
    Application.put_env(:playwright_ex, :test, config)
  end

  test "a bad config raises", %{config: config} do
    Application.put_env(:playwright_ex, :test, config ++ [tracing: :on])

    assert_raise ArgumentError, ~r/unknown keys \[:tracing\] in config :playwright_ex, :test/, fn ->
      Options.artifacts([])
    end

    # `isolate` is an argument only, and error-context.md has no switch, as upstream.
    for key <- [:isolate, :error_context] do
      Application.put_env(:playwright_ex, :test, config ++ [{key, true}])
      assert_raise ArgumentError, ~r/unknown keys \[#{inspect(key)}\]/, fn -> Options.browser([]) end
    end

    Application.put_env(:playwright_ex, :test, config ++ [trace: :sometimes])
    assert_raise ArgumentError, ~r/invalid trace: :sometimes/, fn -> Options.artifacts([]) end
  end
end
