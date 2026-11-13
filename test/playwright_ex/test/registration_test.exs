defmodule PlaywrightEx.Test.RegistrationTest do
  # `use PlaywrightEx.Test`'s per-test registration: the context defaults of every context the
  # test creates on a pooled browser, `info/0`, `output_path/1`.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Client.ClientInstrumentation
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Results
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Test.TestInfo

  setup_all do
    browser = BrowserPool.browser()
    %{browser: browser, playwright: BrowserPool.playwright(browser)}
  end

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

  # The client options of the context `fun` creates with `user_agent: probe`, as the listeners
  # added before this one leave them.
  def options_of(playwright, fun) do
    probe = "probe-#{System.unique_integer([:positive])}"
    test_pid = self()
    instrumentation = Heap.get(playwright, :_instrumentation)

    capture = fn options ->
      if options[:userAgent] == probe, do: send(test_pid, {:options, options})
      options
    end

    listener = %{runBeforeCreateBrowserContext: capture, runBeforeCreateRequestContext: capture}
    ClientInstrumentation.add_listener(instrumentation, listener)

    try do
      fun.(probe)
    after
      ClientInstrumentation.remove_listener(instrumentation, listener)
    end

    assert_receive {:options, options}
    options
  end

  test "every context the test creates gets Playwright Test's context defaults", ctx do
    defaults = &Map.take(options_of(ctx.playwright, &1), Map.keys(@context_defaults))

    assert defaults.(&Browser.new_context!(ctx.browser, user_agent: &1)) == @context_defaults

    assert defaults.(&Task.await(Task.async(fn -> Browser.new_context!(ctx.browser, user_agent: &1) end))) ==
             @context_defaults

    request = &APIRequestContext.dispose!(APIRequest.new_context!(Playwright.request(ctx.playwright), user_agent: &1))
    assert defaults.(request) == @context_defaults

    # Of another worker's browser.
    other = BrowserPool.browser(launch_options: [slow_mo: 1])
    options = options_of(BrowserPool.playwright(other), &Browser.new_context!(other, user_agent: &1))
    assert Map.take(options, Map.keys(@context_defaults)) == @context_defaults
  end

  test "a context option given wins over its default, also nil", ctx do
    options = [locale: "de-DE", viewport: :null, color_scheme: :dark, has_touch: nil]
    given = &Browser.new_context!(ctx.browser, [user_agent: &1] ++ options)

    assert %{locale: "de-DE", viewport: :null, colorScheme: "dark", hasTouch: nil, offline: false} =
             options_of(ctx.playwright, given)

    context = Browser.new_context!(ctx.browser, viewport: :null)
    assert Page.viewport_size(BrowserContext.new_page!(context)) == nil
  end

  test "a context outside a test keeps the client's defaults, and fails no registration", ctx do
    test_pid = self()

    outside = fn probe ->
      spawn(fn -> send(test_pid, {:context, Browser.new_context!(ctx.browser, user_agent: probe)}) end)
      assert_receive {:context, context}
      BrowserContext.close!(context)
    end

    assert Map.take(options_of(ctx.playwright, outside), Map.keys(@context_defaults)) == %{}
  end

  test "a context on a driver of your own gets no defaults and no recording" do
    name = :"#{inspect(__MODULE__)}.own"
    start_supervised!({PlaywrightEx.Supervisor, name: name})
    playwright = PlaywrightEx.playwright(name)
    browser = PlaywrightEx.BrowserType.launch!(PlaywrightEx.TestBrowser.browser_type(playwright))
    own = &Browser.new_context!(browser, user_agent: &1)
    assert Map.take(options_of(playwright, own), Map.keys(@context_defaults)) == %{}
    assert Recorder.lookup(self()) == nil
  end

  test "info: the running test, also in a Task; outside a test it raises" do
    info = PlaywrightEx.Test.info()
    assert info.test_pid == self()
    assert info.file == Path.expand(__ENV__.file)
    assert info.test_name == "info: the running test, also in a Task; outside a test it raises"

    assert info.output_dir ==
             Path.expand(
               TestInfo.output_dir(%{module: __MODULE__, test: :"test #{info.test_name}", file: __ENV__.file})
             )

    assert Task.await(Task.async(&PlaywrightEx.Test.info/0)) == info

    test_pid = self()
    spawn(fn -> send(test_pid, {:raised, catch_error(PlaywrightEx.Test.info())}) end)

    assert_receive {:raised,
                    %RuntimeError{message: "PlaywrightEx.Test.info() can only be called while a test is running" <> _}}
  end

  # Upstream's `testInfo.timeout`: ExUnit's timeout of the test, none (`:infinity`) under `--trace`.
  test "info: the timeout is the config's" do
    config = ExUnit.configuration()
    assert PlaywrightEx.Test.info().timeout == if(config[:trace], do: :infinity, else: config[:timeout])
  end

  @tag timeout: 12_345
  test "info: the timeout is the test's tag" do
    trace? = ExUnit.configuration()[:trace]
    assert PlaywrightEx.Test.info().timeout == if(trace?, do: :infinity, else: 12_345)
    assert PlaywrightEx.Test.info(self()).timeout == PlaywrightEx.Test.info().timeout
  end

  test "output_path is a path in the test's output dir, created" do
    dir = PlaywrightEx.Test.info().output_dir
    on_exit(fn -> File.rm_rf!(dir) end)
    assert PlaywrightEx.Test.output_path("export.csv") == Path.join(dir, "export.csv")
    assert File.dir?(dir)
    assert_raise ArgumentError, ~r/outside of the output dir/, fn -> PlaywrightEx.Test.output_path("../export.csv") end
  end

  test "with every artifact off, nothing is written and no recorder runs for a test without contexts" do
    assert Recorder.lookup(self()) == nil
    refute File.exists?(PlaywrightEx.Test.info().output_dir)
  end

  # Kept on failure only, so the passing test leaves no files.
  @tag trace: :retain_on_failure
  test "a traced test's recorder starts at its registration, for its steps" do
    assert is_pid(Recorder.lookup(self()))
  end

  test "a test's first context starts its recorder", ctx do
    assert Recorder.lookup(self()) == nil
    Browser.new_context!(ctx.browser)
    assert is_pid(Recorder.lookup(self()))
  end

  test "registration is once per test" do
    assert PlaywrightEx.Test.__setup__(%{test_pid: self()}) == :ok
    assert [_] = :ets.lookup(Results.table(), {:test, self()})
  end
end

defmodule PlaywrightEx.Test.RegistrationTest.SetupAllContextTest do
  # A context in `setup_all`, as upstream's `newContext` in `beforeAll`: no defaults, no
  # recording, and no raise at the tests' registration.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.BrowserPool

  setup_all do
    browser = BrowserPool.browser()
    playwright = BrowserPool.playwright(browser)
    test_pid = self()

    options =
      PlaywrightEx.Test.RegistrationTest.options_of(playwright, fn probe ->
        send(test_pid, {:context, Browser.new_context!(browser, user_agent: probe)})
      end)

    assert_received {:context, context}
    on_exit(fn -> BrowserContext.close!(context) end)
    %{shared_context: context, options: options}
  end

  test "a context of the module's, open across its tests, without the defaults", ctx do
    refute Map.has_key?(ctx.options, :locale) or Map.has_key?(ctx.options, :acceptDownloads)
    page = BrowserContext.new_page!(ctx.shared_context)
    Page.set_content!(page, "<p>shared</p>")
    assert Page.text_content!(page, "p") == "shared"
  end
end

defmodule PlaywrightEx.Test.RegistrationTest.TemplateCase do
  # A case template whose `setup` creates a context: `use PlaywrightEx.Test` first in its body
  # registers the test before it.
  use ExUnit.CaseTemplate
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.BrowserPool

  using do
    quote do
      use PlaywrightEx.Test
    end
  end

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  setup %{browser: browser} do
    playwright = BrowserPool.playwright(browser)
    test_pid = self()
    # The client options of the context, as the listeners added before this one leave them.
    probe = &PlaywrightEx.Test.RegistrationTest.options_of(playwright, &1)
    options = probe.(&Browser.new_context!(browser, user_agent: &1))
    send(test_pid, {:options, options})
    :ok
  end
end

defmodule PlaywrightEx.Test.RegistrationTest.TemplateTest do
  use PlaywrightEx.Test.RegistrationTest.TemplateCase, async: true

  alias PlaywrightEx.Test.Recorder

  @tag trace: :retain_on_failure
  test "a context of the case template's setup gets the defaults and is recorded" do
    assert_received {:options, %{locale: "en-US", viewport: %{width: 1280, height: 720}}}
    assert [%{}] = :sys.get_state(Recorder.lookup(self())).contexts
  end
end

defmodule PlaywrightEx.Test.RegistrationTest.TwiceTest do
  # The template's `using` brings `use PlaywrightEx.Test`, and the module adds its own: once.
  use PlaywrightEx.Test.RegistrationTest.TemplateCase, async: true
  use PlaywrightEx.Test

  test "a second use is a no-op" do
    assert_received {:options, %{locale: "en-US"}}
    assert [_] = :ets.lookup(PlaywrightEx.Test.Results.table(), {:test, self()})
  end
end

defmodule PlaywrightEx.Test.RegistrationTest.LateTest do
  use ExUnit.Case, async: true

  test "a context before the registration makes it raise, with the fix" do
    test_pid = self()
    browser = PlaywrightEx.Test.BrowserPool.browser()

    # A template's `setup` that creates a context, then the registration, as a test of a template
    # with `use PlaywrightEx.Test` only in its `using` runs them; in a process of its own.
    spawn(fn ->
      PlaywrightEx.Browser.new_context!(browser)

      result =
        try do
          PlaywrightEx.Test.__setup__(%{test_pid: self()})
        rescue
          e in ArgumentError -> e.message
        end

      send(test_pid, {:result, result})
    end)

    assert_receive {:result, message}
    assert message =~ "this test created a context before `use PlaywrightEx.Test` registered it"
    assert message =~ "add `use PlaywrightEx.Test` as the first line of the case template's body"
  end
end
