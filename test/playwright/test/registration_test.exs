defmodule Playwright.Test.RegistrationTest do
  # `use Playwright.Test`'s per-test registration: the context defaults of every context the
  # test creates on a pooled browser, `info/0`, `output_path/1`.
  use ExUnit.Case, async: true
  use Playwright.Test

  alias Playwright.APIRequest
  alias Playwright.APIRequestContext
  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Client.ClientInstrumentation
  alias Playwright.Page
  alias Playwright.Runtime.Heap
  alias Playwright.Test.BrowserPool
  alias Playwright.Test.Results
  alias Playwright.Test.Recorder
  alias Playwright.Test.TestInfo

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
    start_supervised!({Playwright.Supervisor, name: name})
    playwright = Playwright.instance(name)
    browser = Playwright.BrowserType.launch!(Playwright.TestBrowser.browser_type(playwright))
    own = &Browser.new_context!(browser, user_agent: &1)
    assert Map.take(options_of(playwright, own), Map.keys(@context_defaults)) == %{}
    assert Recorder.lookup(self()) == nil
  end

  test "info: the running test, also in a Task; outside a test it raises" do
    info = Playwright.Test.info()
    assert info.test_pid == self()
    assert info.file == Path.expand(__ENV__.file)
    assert info.test_name == "info: the running test, also in a Task; outside a test it raises"

    dir = Path.expand(TestInfo.output_dir(%{module: __MODULE__, test: :"test #{info.test_name}", file: __ENV__.file}))
    # `-retryN` under `mix test --failed`.
    assert info.output_dir =~ ~r/^#{Regex.escape(dir)}(-retry\d+)?$/
    # Upstream's `testInfo.retry`: 0 unless under `mix test --failed`.
    assert info.retry == if(ExUnit.configuration()[:only_test_ids], do: info.retry, else: 0)
    assert info.output_dir == if(info.retry > 0, do: "#{dir}-retry#{info.retry}", else: dir)

    assert Task.await(Task.async(&Playwright.Test.info/0)) == info

    test_pid = self()
    spawn(fn -> send(test_pid, {:raised, catch_error(Playwright.Test.info())}) end)

    assert_receive {:raised,
                    %RuntimeError{message: "Playwright.Test.info() can only be called while a test is running" <> _}}
  end

  # Upstream's `testInfo.timeout`: ExUnit's timeout of the test, none (`:infinity`) under `--trace`.
  test "info: the timeout is the config's" do
    config = ExUnit.configuration()
    assert Playwright.Test.info().timeout == if(config[:trace], do: :infinity, else: config[:timeout])
  end

  @tag timeout: 12_345
  test "info: the timeout is the test's tag" do
    trace? = ExUnit.configuration()[:trace]
    assert Playwright.Test.info().timeout == if(trace?, do: :infinity, else: 12_345)
    assert Playwright.Test.info(self()).timeout == Playwright.Test.info().timeout
  end

  # ExUnit's kill time: the test's start (its first setup callback) plus its timeout. And the
  # contexts' close before it, upstream's internal `testInfo._deadline()`. The same from any
  # process.
  @tag timeout: 12_345
  test "info: the deadline is the test's start plus its timeout, the contexts close before it" do
    %{deadline: deadline, close_deadline: close_deadline} = Playwright.Test.info()

    if ExUnit.configuration()[:trace] do
      assert deadline == :infinity
      assert close_deadline == :infinity
    else
      now = System.monotonic_time(:millisecond)
      assert deadline > now and deadline <= now + 12_345
      # `min(1000, 12_345 / 20)`
      assert close_deadline == deadline - 617
      info = Task.await(Task.async(fn -> Playwright.Test.info() end))
      assert {info.deadline, info.close_deadline} == {deadline, close_deadline}
      assert Playwright.Test.info(self()).close_deadline == close_deadline
    end
  end

  @tag timeout: :infinity
  test "info: no deadline without a timeout" do
    assert %{deadline: :infinity, close_deadline: :infinity} = Playwright.Test.info()
  end

  test "in_registered_test?: in the test and its Tasks, not in other processes" do
    assert Playwright.Test.in_registered_test?()
    assert Task.await(Task.async(&Playwright.Test.in_registered_test?/0))
    test_pid = self()
    spawn(fn -> send(test_pid, {:registered?, Playwright.Test.in_registered_test?()}) end)
    assert_receive {:registered?, false}
  end

  test "output_path is a path in the test's output dir, created" do
    dir = Playwright.Test.info().output_dir
    on_exit(fn -> File.rm_rf!(dir) end)
    assert Playwright.Test.output_path("export.csv") == Path.join(dir, "export.csv")
    assert File.dir?(dir)
    assert_raise ArgumentError, ~r/outside of the output dir/, fn -> Playwright.Test.output_path("../export.csv") end
  end

  test "with every artifact off, nothing is written and no recorder runs for a test without contexts" do
    assert Recorder.lookup(self()) == nil
    refute File.exists?(Playwright.Test.info().output_dir)
  end

  # Kept on failure only, so the passing test leaves no files.
  @tag Playwright.Test.use(trace: :retain_on_failure)
  test "a traced test's recorder starts at its registration, for its steps" do
    assert is_pid(Recorder.lookup(self()))
  end

  test "a test's first context starts its recorder", ctx do
    assert Recorder.lookup(self()) == nil
    Browser.new_context!(ctx.browser)
    assert is_pid(Recorder.lookup(self()))
  end

  test "registration is once per test" do
    assert Playwright.Test.__setup__(%{test_pid: self()}) == :ok
    assert [_] = :ets.lookup(Results.table(), {:test, self()})
  end
end

defmodule Playwright.Test.RegistrationTest.SetupAllContextTest do
  # A context in `setup_all`, as upstream's `newContext` in `beforeAll` (its `all-hooks-included`
  # fixtures): the defaults, and no raise at the tests' registration. The config's options:
  # `Playwright.Test.SetupAllTest`.
  use ExUnit.Case, async: true
  use Playwright.Test

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Page
  alias Playwright.Test.BrowserPool

  setup_all do
    browser = BrowserPool.browser()
    playwright = BrowserPool.playwright(browser)
    test_pid = self()

    options =
      Playwright.Test.RegistrationTest.options_of(playwright, fn probe ->
        send(test_pid, {:context, Browser.new_context!(browser, user_agent: probe, locale: "de-DE")})
      end)

    assert_received {:context, context}
    on_exit(fn -> BrowserContext.close!(context) end)
    %{shared_context: context, options: options}
  end

  test "a context of the module's, open across its tests, with the defaults", ctx do
    assert %{locale: "de-DE", acceptDownloads: true, viewport: %{width: 1280, height: 720}} = ctx.options
    page = BrowserContext.new_page!(ctx.shared_context)
    Page.set_content!(page, "<p>shared</p>")
    assert Page.text_content!(page, "p") == "shared"
  end
end

defmodule Playwright.Test.RegistrationTest.TemplateCase do
  # A case template whose `setup` creates a context: `use Playwright.Test` first in its body
  # registers the test before it.
  use ExUnit.CaseTemplate
  use Playwright.Test

  alias Playwright.Browser
  alias Playwright.Test.BrowserPool

  using do
    quote do
      use Playwright.Test
    end
  end

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  setup %{browser: browser} do
    playwright = BrowserPool.playwright(browser)
    test_pid = self()
    # The client options of the context, as the listeners added before this one leave them.
    probe = &Playwright.Test.RegistrationTest.options_of(playwright, &1)
    options = probe.(&Browser.new_context!(browser, user_agent: &1))
    send(test_pid, {:options, options})
    :ok
  end
end

defmodule Playwright.Test.RegistrationTest.TemplateTest do
  use Playwright.Test.RegistrationTest.TemplateCase, async: true

  alias Playwright.Test.Recorder

  @tag Playwright.Test.use(trace: :retain_on_failure)
  test "a context of the case template's setup gets the defaults and is recorded" do
    assert_received {:options, %{locale: "en-US", viewport: %{width: 1280, height: 720}}}
    assert [%{}] = :sys.get_state(Recorder.lookup(self())).contexts
  end
end

defmodule Playwright.Test.RegistrationTest.TwiceTest do
  # The template's `using` brings `use Playwright.Test`, and the module adds its own: once.
  use Playwright.Test.RegistrationTest.TemplateCase, async: true
  use Playwright.Test

  test "a second use registers the test once" do
    assert_received {:options, %{locale: "en-US"}}
    assert [_] = :ets.lookup(Playwright.Test.Results.table(), {:test, self()})
  end
end

defmodule Playwright.Test.RegistrationTest.LateTest do
  use ExUnit.Case, async: true

  test "a context before the registration makes it raise, with the fix" do
    test_pid = self()
    browser = Playwright.Test.BrowserPool.browser()

    # A template's `setup` that creates a context, then the registration, as a test of a template
    # with `use Playwright.Test` only in its `using` runs them; in a process of its own.
    spawn(fn ->
      Playwright.Browser.new_context!(browser)

      result =
        try do
          Playwright.Test.__setup__(%{test_pid: self()})
        rescue
          e in ArgumentError -> e.message
        end

      send(test_pid, {:result, result})
    end)

    assert_receive {:result, message}
    assert message =~ "this test created a context before `use Playwright.Test` registered it"
    assert message =~ "add `use Playwright.Test` as the first line of the case template's body"
  end

  test "a context of setup_all before the module's registration makes it raise, with the fix" do
    test_pid = self()
    browser = Playwright.Test.BrowserPool.browser()

    # A template's `setup_all` that creates a context, then the module's registration, as a
    # module of a template with `use Playwright.Test` only in its `using` runs them.
    spawn(fn ->
      context = Playwright.Browser.new_context!(browser)

      result =
        try do
          Playwright.Test.__setup_all__(%{module: __MODULE__})
        rescue
          e in ArgumentError -> e.message
        end

      Playwright.BrowserContext.close!(context)
      send(test_pid, {:result, result, Playwright.Test.Results.scope(self())})
    end)

    assert_receive {:result, message, nil}
    assert message =~ "this module's setup_all created a context before `use Playwright.Test` registered it"
    assert message =~ "add `use Playwright.Test` as the first line of the case template's body, or move"
  end

  # A template's `setup` that calls `BrowserPool.browser/1`, then the registration, in the test's
  # process: the browser had none of the module's worker options.
  test "a browser before the registration makes it raise, with the fix" do
    Playwright.Test.BrowserPool.browser()

    message = assert_raise(ArgumentError, fn -> Playwright.Test.__setup__(%{test_pid: self()}) end).message
    assert message =~ "this test called BrowserPool.browser/1 before `use Playwright.Test` registered it"
    assert message =~ "none of the module's worker options"
    assert message =~ "add `use Playwright.Test` as the first line of the case template's body"
  end

  test "a browser of setup_all before the module's registration makes it raise, with the fix" do
    Playwright.Test.BrowserPool.browser()

    message = assert_raise(ArgumentError, fn -> Playwright.Test.__setup_all__(%{module: __MODULE__}) end).message
    assert message =~ "this module's setup_all called BrowserPool.browser/1 before `use Playwright.Test` registered it"
    assert message =~ "or move the `setup_all` after the module's `use Playwright.Test`"
    assert Playwright.Test.Results.scope(self()) == nil
  end

  # A process that never registers: its browser has the config's options, and nothing raises.
  test "a browser of a test without `use Playwright.Test` is the config's" do
    browser = Playwright.Test.BrowserPool.browser()
    assert browser == Playwright.Test.BrowserPool.browser()
    assert Playwright.Browser.new_context!(browser)
  end
end
