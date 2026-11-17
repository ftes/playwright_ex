defmodule Playwright.Test.ContextOptionsTest do
  # `use Playwright.Test, context_options: [...]` (through `Playwright.Case`), upstream's
  # `test.use({ locale: 'de-DE' })`: over the defaults and the config, under the call's options,
  # for every context of the module's tests and of its `setup_all`.
  use Playwright.Case, async: true, context_options: [locale: "de-DE", color_scheme: :dark]

  alias Playwright.Test.Options

  setup_all %{browser: browser} do
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close!(context) end)
    %{setup_all_page: BrowserContext.new_page!(context)}
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

  test "a context of setup_all gets them", %{setup_all_page: page} do
    assert language(page) == "de-DE"
    assert dark?(page)
  end

  defp compile(name, body) do
    Code.compile_string("""
    defmodule Playwright.Test.ContextOptionsTest.#{name} do
      use ExUnit.Case
      #{body}
    end
    """)
  end

  test "an anonymous function or an invalid value raises at compile time" do
    assert_raise ArgumentError, ~r/invalid context_options: an anonymous function can't be kept/, fn ->
      compile("Anonymous", "use Playwright.Case, context_options: fn _context -> [] end")
    end

    assert_raise ArgumentError, ~r/lokale/, fn ->
      compile("Unknown", "use Playwright.Test, context_options: [lokale: \"de-DE\"]")
    end

    assert_raise ArgumentError, ~r/invalid context_options: :dark, expected a keyword list/, fn ->
      compile("Invalid", "use Playwright.Test, context_options: :dark")
    end
  end

  test "a module's uses merge them per key, a function replaces them" do
    assert __MODULE__.Merged.__playwright_test__(:options).context_options == [color_scheme: :dark, locale: "fr-FR"]

    assert __MODULE__.Replaced.__playwright_test__(:options).context_options ==
             {Playwright.Test.ContextOptionsTest, :options}
  end

  def options(%{lang: lang}), do: %{locale: lang}
  def invalid(_context), do: :dark

  test "{module, function} is called with the test's context, its result checked" do
    assert Options.use_context_options(%{context_options: {__MODULE__, :options}}, %{lang: "fr-FR"}) ==
             [locale: "fr-FR"]

    assert_raise ArgumentError, ~r/the context_options function .*invalid.* returned :dark/, fn ->
      Options.use_context_options(%{context_options: &__MODULE__.invalid/1}, %{})
    end

    assert Options.use_context_options(%{context_options: {__MODULE__, :options}}, nil) == []
  end
end

defmodule Playwright.Test.ContextOptionsTest.FunctionTest do
  # A function of the test's context (`&Mod.fun/1`): its `parameterize:` values (upstream's
  # projects) and `setup_all` values. Not applied in `setup_all`, which has no test.
  use Playwright.Case,
    async: true,
    parameterize: [%{lang: "de-DE"}, %{lang: "fr-FR"}],
    context_options: &__MODULE__.context_options/1

  import Playwright.Test.ContextOptionsTest, only: [language: 1]

  alias Playwright.APIRequest
  alias Playwright.APIRequestContext
  alias Playwright.APIResponse
  alias Playwright.TestServer

  # A `setup_all` context would raise here: no `test`.
  def context_options(%{test: _, lang: lang, server: server}), do: [locale: lang, base_url: server.prefix]

  setup_all %{browser: browser} do
    server = TestServer.server(start_supervised!({TestServer, dir_path: System.tmp_dir!()}))
    TestServer.set_content(server, "/", "<p>home</p>", "text/html")
    TestServer.set_content(server, "/api", ~s({"ok": true}), "application/json")

    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close!(context) end)
    %{server: server, setup_all_page: BrowserContext.new_page!(context)}
  end

  test "the case's page gets the function's options", %{page: page, lang: lang, server: server} do
    assert language(page) == lang
    Page.goto!(page, "/")
    assert Page.url(page) == server.prefix <> "/"
  end

  test "a request context gets them", %{browser: browser} do
    request = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))
    assert APIResponse.status(APIRequestContext.get!(request, "/api")) == 200
  end

  test "the call's options win", %{browser: browser} do
    page = BrowserContext.new_page!(Browser.new_context!(browser, locale: "it-IT"))
    assert language(page) == "it-IT"
  end

  test "a context of setup_all gets no function's options", %{setup_all_page: page} do
    assert language(page) == "en-US"
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

  use Playwright.Case, context_options: [locale: "fr-FR"]

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
  use Playwright.Test, context_options: [locale: "de-DE", color_scheme: :dark]
  use Playwright.Test, context_options: %{locale: "fr-FR"}
end

defmodule Playwright.Test.ContextOptionsTest.Replaced do
  use ExUnit.Case, async: true
  use Playwright.Test, context_options: [locale: "de-DE"]
  use Playwright.Test, context_options: {Playwright.Test.ContextOptionsTest, :options}
end
