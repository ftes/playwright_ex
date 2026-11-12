defmodule PlaywrightEx.Test.FragmentsTest do
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
  alias PlaywrightEx.Test.Recorder

  setup_all :browser
  setup [:new_context, :new_page]

  test "browser, context and page", ctx do
    assert %{playwright: %PlaywrightEx.Playwright{}, browser_name: browser_name, browser: browser} = ctx
    assert browser_name == String.to_atom(PlaywrightEx.TestBrowser.name())
    assert BrowserContext.browser(ctx.context) == browser
    assert ctx.page in BrowserContext.pages(ctx.context)
    Page.set_content!(ctx.page, "<h1>Hi</h1>")
    assert Page.text_content!(ctx.page, "h1") == "Hi"
  end

  test "with every artifact off, nothing is written", ctx do
    refute File.exists?(Recorder.output_dir(ctx))
  end

  test "output_path is a path in the test's output dir, created", ctx do
    dir = Recorder.output_dir(ctx)
    on_exit(fn -> File.rm_rf!(dir) end)
    assert output_path(ctx, "export.csv") == Path.join(dir, "export.csv")
    assert File.dir?(dir)
    assert_raise ArgumentError, ~r/outside of the output dir/, fn -> output_path(ctx, "../export.csv") end
  end

  test "new_context passes context_options as is", ctx do
    %{context: context} = new_context(ctx, context_options: [locale: "de-DE", viewport: %{width: 400, height: 300}])
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, "navigator.language") == "de-DE"
    assert Page.viewport_size(page) == %{width: 400, height: 300}
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
  defp options_of(playwright, fun) do
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

    assert defaults.(&new_context(ctx, context_options: [user_agent: &1])) == @context_defaults
    assert defaults.(&Browser.new_context!(ctx.browser, user_agent: &1)) == @context_defaults

    assert defaults.(&Task.await(Task.async(fn -> Browser.new_context!(ctx.browser, user_agent: &1) end))) ==
             @context_defaults

    request = &APIRequestContext.dispose!(APIRequest.new_context!(Playwright.request(ctx.playwright), user_agent: &1))
    assert defaults.(request) == @context_defaults
  end

  test "a context option given wins over its default, also nil", ctx do
    options = [locale: "de-DE", viewport: :null, color_scheme: :dark, has_touch: nil]
    given = &Browser.new_context!(ctx.browser, [user_agent: &1] ++ options)

    assert %{locale: "de-DE", viewport: :null, colorScheme: "dark", hasTouch: nil, offline: false} =
             options_of(ctx.playwright, given)

    %{context: context} = new_context(ctx, context_options: [viewport: :null])
    assert Page.viewport_size(BrowserContext.new_page!(context)) == nil
  end

  test "a context outside a test keeps the client's defaults", ctx do
    test_pid = self()

    outside = fn probe ->
      spawn(fn -> send(test_pid, {:context, Browser.new_context!(ctx.browser, user_agent: probe)}) end)
      assert_receive {:context, context}
      BrowserContext.close!(context)
    end

    assert Map.take(options_of(ctx.playwright, outside), Map.keys(@context_defaults)) == %{}
  end

  test "new_context with the test's context map raises outside the test", ctx do
    test_pid = self()

    spawn(fn ->
      result =
        try do
          new_context(ctx)
        rescue
          e in ArgumentError -> e.message
        end

      send(test_pid, {:result, result})
    end)

    assert_receive {:result, message}
    assert message =~ "new_context/2 got a test's context map outside the test"
  end

  test "a second browser/1 with other options is another browser", %{browser: browser} do
    %{browser: other} = browser(launch_options: [timeout: 30_001])
    assert other != browser
    assert Browser.is_connected(other)
  end
end

defmodule PlaywrightEx.Test.SetupAllContextTest do
  # `new_context/2` in `setup_all`, as upstream's `newContext` in `beforeAll`: nothing records or
  # closes it.
  use ExUnit.Case, async: true

  use PlaywrightEx.Test

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page

  setup_all ctx do
    %{context: context} = new_context(Map.merge(ctx, browser(ctx)))
    on_exit(fn -> BrowserContext.close!(context) end)
    %{shared_context: context}
  end

  test "a context of the module's, open across its tests", %{shared_context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<p>shared</p>")
    assert Page.text_content!(page, "p") == "shared"
  end
end

defmodule PlaywrightEx.Test.UserBrowserTest do
  # A `setup_all` of the user's own makes `%{browser: _}`; the other fragments take it.
  use ExUnit.Case, async: true

  use PlaywrightEx.Test

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.TestBrowser

  setup_all %{module: module} do
    start_supervised!({PlaywrightEx.Supervisor, name: module})
    %{browser: BrowserType.launch!(TestBrowser.browser_type(PlaywrightEx.playwright(module)))}
  end

  # Registered first, so it runs after the recording's `on_exit`.
  setup ctx do
    dir = Recorder.output_dir(ctx)

    on_exit(fn ->
      assert File.exists?(Path.join(dir, "trace.zip"))
      File.rm_rf!(dir)
    end)
  end

  setup ctx, do: record_artifacts(ctx, trace: :on)
  setup [:new_context, :new_page]

  test "a recorded context and page of the user's browser", %{browser: browser, context: context, page: page} do
    assert BrowserContext.browser(context) == browser
    Page.set_content!(page, "<h1>Mine</h1>")
    assert Page.text_content!(page, "h1") == "Mine"
  end
end

defmodule PlaywrightEx.Test.CaseTemplateDefaultsCase do
  # A case template whose `setup` creates the context: it runs before `use PlaywrightEx.Test`'s.
  use ExUnit.CaseTemplate

  alias PlaywrightEx.Client.ClientInstrumentation
  alias PlaywrightEx.Runtime.Heap

  using do
    quote do
      use PlaywrightEx.Test
    end
  end

  setup_all ctx, do: PlaywrightEx.Test.browser(ctx)

  # The client options of the context, as the listeners added before this one leave them.
  setup ctx do
    test_pid = self()
    instrumentation = Heap.get(ctx.playwright, :_instrumentation)
    capture = fn options -> if self() == test_pid, do: send(test_pid, {:options, options}), else: options end
    listener = %{runBeforeCreateBrowserContext: &tap(&1, capture)}
    ClientInstrumentation.add_listener(instrumentation, listener)

    try do
      PlaywrightEx.Test.new_context(ctx)
    after
      ClientInstrumentation.remove_listener(instrumentation, listener)
    end
  end
end

defmodule PlaywrightEx.Test.CaseTemplateDefaultsTest do
  use PlaywrightEx.Test.CaseTemplateDefaultsCase, async: true

  test "a context of the case template's setup gets the context defaults" do
    assert_received {:options, %{locale: "en-US", viewport: %{width: 1280, height: 720}}}
  end
end
