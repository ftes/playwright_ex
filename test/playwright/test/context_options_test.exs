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

    # A mistyped option, not a `{Mod, :fun}`; an Erlang-named module not compiled yet is fine.
    assert_raise ArgumentError, ~r/invalid context_options: \{:color_scheme, :dark\}, expected options/, fn ->
      compile("Tuple", "use Playwright.Test, context_options: {:color_scheme, :dark}")
    end

    assert Options.use_options(context_options: {:not_compiled_yet, :opts}).context_options == [
             {:not_compiled_yet, :opts}
           ]
  end

  defp resolve(module, context \\ %{lang: "it-IT"}),
    do: Options.use_context_options(module.__playwright_test__(:options), context)

  test "a module's uses apply in order, each over the earlier per key, a function's result too" do
    assert resolve(__MODULE__.Merged) == %{colorScheme: "dark", locale: "fr-FR"}
    # The function after the options, and before them.
    assert resolve(__MODULE__.FunctionLast) == %{colorScheme: "dark", locale: "it-IT"}
    assert resolve(__MODULE__.FunctionFirst) == %{colorScheme: "dark", locale: "de-DE"}
    # In `setup_all`, the options only, and none if a `use` gives a function.
    assert resolve(__MODULE__.Merged, nil) == %{colorScheme: "dark", locale: "fr-FR"}
    assert resolve(__MODULE__.FunctionLast, nil) == %{}
    assert resolve(__MODULE__.FunctionFirst, nil) == %{}
    # The last of duplicated keys wins, a nil too.
    assert resolve(__MODULE__.Duplicated) == %{locale: "fr-FR"}
  end

  test "a function given again (a template's using and the module's own use) is kept where it came first" do
    assert [function, %{}] = __MODULE__.Twice.__playwright_test__(:options).context_options
    assert function == (&__MODULE__.options/1)
  end

  test "a nil option resets it past the earlier uses, to the config's or the default" do
    # `[locale: "fr-FR"]`, then `[locale: nil]`.
    module_options = resolve(__MODULE__.NilOption)
    assert module_options == %{colorScheme: "dark"}

    assert %{locale: "de-DE", colorScheme: "dark"} =
             Options.context_options(%{context_options: [locale: "de-DE"]}, module_options)

    assert %{locale: "en-US"} = Options.context_options(%{context_options: []}, module_options)
    # A function's nil too, and a later option over the reset.
    assert resolve(__MODULE__.NilFunction) == %{colorScheme: "dark"}
    assert resolve(__MODULE__.NilFunction, %{lang: "it-IT", reset: false}) == %{colorScheme: "dark", locale: "it-IT"}
    # The config's nil falls back to Playwright Test's default.
    assert %{locale: "en-US"} = Options.context_options(%{context_options: [locale: nil]})
  end

  def maybe_reset(%{lang: lang} = context), do: [locale: if(Map.get(context, :reset, true), do: nil, else: lang)]

  def options(%{lang: lang}), do: %{locale: lang}
  def invalid(_context), do: :dark
  def unknown(_context), do: [lokale: "de-DE"]

  test "a function is called with the test's context, its existence and result checked" do
    assert Options.use_context_options(%{context_options: [{__MODULE__, :options}]}, %{lang: "fr-FR"}) ==
             %{locale: "fr-FR"}

    assert_raise ArgumentError,
                 ~r/context_options: Playwright.Test.ContextOptionsTest.invalid\/1 returned an invalid option: .*:dark/,
                 fn ->
                   Options.use_context_options(%{context_options: [&__MODULE__.invalid/1]}, %{})
                 end

    assert_raise ArgumentError,
                 ~r/context_options: Playwright.Test.ContextOptionsTest.unknown\/1 returned an invalid option: .*lokale/,
                 fn -> Options.use_context_options(%{context_options: [&__MODULE__.unknown/1]}, %{}) end

    assert_raise ArgumentError,
                 ~r/context_options: \{Playwright.Test.ContextOptionsTest, :missing\} is undefined \(no Playwright.Test.ContextOptionsTest.missing\/1\)/,
                 fn -> Options.use_context_options(%{context_options: [{__MODULE__, :missing}]}, %{}) end
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

defmodule Playwright.Test.ContextOptionsTest.MixedTest do
  # Options and a function: `setup_all`'s contexts get none of them, its tests all.
  use Playwright.Case, async: true, context_options: [locale: "de-DE"]
  use Playwright.Test, context_options: &__MODULE__.dark/1

  import Playwright.Test.ContextOptionsTest, only: [language: 1, dark?: 1]

  def dark(%{test: _}), do: [color_scheme: :dark]

  setup_all %{browser: browser} do
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close!(context) end)
    %{setup_all_page: BrowserContext.new_page!(context)}
  end

  test "a test's page gets both", %{page: page} do
    assert language(page) == "de-DE"
    assert dark?(page)
  end

  test "a context of setup_all gets neither", %{setup_all_page: page} do
    assert language(page) == "en-US"
    refute dark?(page)
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

defmodule Playwright.Test.ContextOptionsTest.FunctionLast do
  use ExUnit.Case, async: true
  use Playwright.Test, context_options: [locale: "de-DE", color_scheme: :dark]
  use Playwright.Test, context_options: {Playwright.Test.ContextOptionsTest, :options}
end

defmodule Playwright.Test.ContextOptionsTest.FunctionFirst do
  use ExUnit.Case, async: true
  use Playwright.Test, context_options: &Playwright.Test.ContextOptionsTest.options/1
  use Playwright.Test, context_options: [locale: "de-DE", color_scheme: :dark]
end

defmodule Playwright.Test.ContextOptionsTest.NilOption do
  use ExUnit.Case, async: true
  use Playwright.Test, context_options: [locale: "fr-FR", color_scheme: :dark]
  use Playwright.Test, context_options: [locale: nil]
end

defmodule Playwright.Test.ContextOptionsTest.NilFunction do
  use ExUnit.Case, async: true
  use Playwright.Test, context_options: [locale: "fr-FR", color_scheme: :dark]
  use Playwright.Test, context_options: &Playwright.Test.ContextOptionsTest.maybe_reset/1
end

defmodule Playwright.Test.ContextOptionsTest.Duplicated do
  use ExUnit.Case, async: true
  use Playwright.Test, context_options: [locale: nil, locale: "fr-FR"]
end

defmodule Playwright.Test.ContextOptionsTest.Twice do
  use ExUnit.Case, async: true
  use Playwright.Test, context_options: &Playwright.Test.ContextOptionsTest.options/1
  use Playwright.Test, context_options: [locale: "de-DE"]
  use Playwright.Test, context_options: &Playwright.Test.ContextOptionsTest.options/1
end
