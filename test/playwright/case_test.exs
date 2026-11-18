defmodule Playwright.CaseTest.Extended do
  # A template built on `Playwright.Case`: setup in its `using` runs after the page's (its own
  # `setup` would run before them).
  use ExUnit.CaseTemplate

  using do
    quote do
      use Playwright.Case

      setup %{page: page} do
        Playwright.Page.set_content!(page, "<h1>Extended</h1>")
        :ok
      end
    end
  end
end

defmodule Playwright.CaseTest.NoConfiguredBrowser do
  # A template without the config's `browser_name` for its module's run, so a device picks the
  # browser. Its own `setup_all` runs before `Playwright.Case`'s registers the module.
  use ExUnit.CaseTemplate

  setup_all do
    env = Application.get_env(:playwright, :test)
    on_exit(fn -> Application.put_env(:playwright, :test, env) end)
    Application.put_env(:playwright, :test, Keyword.delete(env, :browser_name))
  end

  using opts do
    quote do
      use Playwright.Case, unquote(opts)
    end
  end
end

defmodule Playwright.CaseTest do
  use Playwright.Case, async: true

  setup_all %{browser_name: browser_name} do
    %{setup_all_browser_name: browser_name}
  end

  test "the module's browser_name, in setup_all and the test", ctx do
    assert ctx.browser_name == String.to_existing_atom(Playwright.TestBrowser.name())
    assert ctx.setup_all_browser_name == ctx.browser_name
  end

  test "a test gets a context of the module's browser and a page of it, recorded", ctx do
    %{browser: browser, context: context, page: page} = ctx
    assert Page.context(page) == context
    assert BrowserContext.browser(context) == browser
    # The module holds it (`setup_all`): the test's own call is the module's.
    assert BrowserPool.browser() == browser
    assert is_pid(Playwright.Test.Recorder.lookup(self()))
    Page.set_content!(page, "<h1>Hi</h1>")
    Page.get_by_role(page, :heading) |> Expect.to_have_text!("Hi")
  end

  test "the context has Playwright Test's defaults", %{page: page} do
    assert Page.evaluate!(page, "navigator.language") == "en-US"
    assert Page.viewport_size(page) == %{width: 1280, height: 720}
  end
end

defmodule Playwright.CaseTest.ExtendedTest do
  use Playwright.CaseTest.Extended, async: true

  test "a template's setup after the page's", %{page: page} do
    Page.get_by_role(page, :heading) |> Expect.to_have_text!("Extended")
  end
end

defmodule Playwright.CaseTest.BrowserNameParameterTest do
  # A parameter of the same name is replaced by the module's browser_name.
  use Playwright.Case,
    async: true,
    parameterize: [Map.put(Playwright.Test.parameters([]), :browser_name, "the parameter's")]

  test "the module's browser_name over a parameter's", %{browser_name: browser_name} do
    assert browser_name == String.to_existing_atom(Playwright.TestBrowser.name())
  end
end

defmodule Playwright.CaseTest.BrowserNameUseTest do
  # Launches WebKit: run when it is the browser under test (CI installs one browser).
  use Playwright.Case, async: true, browser_name: :webkit

  @moduletag skip: if(Playwright.TestBrowser.name() != "webkit", do: "needs WebKit")

  setup_all %{browser_name: browser_name} do
    %{setup_all_browser_name: browser_name}
  end

  test "the module's use option", ctx do
    assert ctx.browser_name == :webkit
    assert ctx.setup_all_browser_name == :webkit
  end
end

defmodule Playwright.CaseTest.BrowserNameDeviceTest do
  # A device project without a browser_name (in the config either) picks the browser. Sync: it
  # changes the config. Launches Firefox: run when it is the browser under test.
  use Playwright.CaseTest.NoConfiguredBrowser,
    async: false,
    parameterize: [Playwright.Test.parameters(Playwright.device("Desktop Firefox"))]

  @moduletag skip: if(Playwright.TestBrowser.name() != "firefox", do: "needs Firefox")

  test "the device's default_browser_type", %{browser_name: browser_name} do
    refute Keyword.has_key?(Application.get_env(:playwright, :test), :browser_name)
    assert browser_name == :firefox
  end
end
