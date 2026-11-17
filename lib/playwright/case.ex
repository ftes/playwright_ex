defmodule Playwright.Case do
  @moduledoc """
  A case template with Playwright Test's default fixtures: the module holds a `browser`
  (`Playwright.Test.BrowserPool.browser/1` in `setup_all`, upstream's worker for the file), and
  each test gets a `context` of it and a `page`, recorded as the `:test` config and the test's
  tags say (see `Playwright.Test`).

      defmodule MyApp.SignUpTest do
        use Playwright.Case, async: true

        test "signs up", %{page: page} do
          Page.goto!(page, "/sign-up")
          Expect.to_have_title!(page, "Sign up")
        end
      end

  It takes `use Playwright.Test`'s options next to ExUnit.Case's: `use Playwright.Case,
  async: true, trace: :on`. `locale: "de-DE"` is upstream's `test.use({ locale: 'de-DE' })`,
  for the `context` and every other context of the module; a device is `use Playwright.Test,
  Playwright.device("iPhone 13")` after it, which also picks the `browser`, as does
  `browser_name:`;
  for a describe block or a test, `@describetag Test.use(...)` or `@tag Test.use(...)`, and for
  projects, `parameterize:` with `Playwright.Test.parameters/1`, see "Context defaults" and
  "Browser" in `Playwright.Test`. Any other option
  raises, so a template that forwards its options here pops its own first: `{sandbox, opts} =
  Keyword.pop(opts, :sandbox)` in its `using opts`, then `use Playwright.Case, unquote(opts)`.

  It only puts the pieces together, so it is a recipe as much as an API: `use Playwright.Test`
  first in the body, so the test is registered before the context is created, the browser in
  `setup_all`, then the context and page from the plain API. To add setup that runs after these, `use
  Playwright.Case` in your own template's `using` and put the setup after it there (a
  template's own `setup` runs before the ones its `using` brings in):

      using do
        quote do
          use Playwright.Case
          setup %{page: page}, do: MyApp.Auth.log_in(page)
        end
      end

  When the `context` can't be configured enough (values only the module's own `setup` computes,
  as ExUnit runs the template's `setup` first, or options that differ per test), create your
  own context in the test or its `setup`: `Browser.new_context!(browser, storage_state: state)`.
  It still gets the defaults and the options of every level (the config's, the project's, the
  module's, the describe's and the test's), and is recorded.

  A module that shares one page from `setup_all` (upstream's `beforeAll` page) would still pay
  for each test's `context` and `page`, about 40 ms per test on Chromium and 120 ms on Firefox:
  skip `Playwright.Case` and write the few lines yourself. The `setup_all` context gets the
  defaults, the config's, the project's and the module's context options and the timeouts, but no test records it (it is in no trace, screenshot or `error-context.md`):

      use ExUnit.Case, async: true
      use Playwright.Test

      alias Playwright.{Browser, BrowserContext, Page}
      alias Playwright.Test.BrowserPool

      setup_all do
        context = Browser.new_context!(BrowserPool.browser())
        on_exit(fn -> BrowserContext.close!(context) end)
        %{page: BrowserContext.new_page!(context)}
      end

  To change a piece (another browser, other aliases), copy this module's source into
  `test/support` and edit it there.

  Playwright Test's `request` fixture is not here, as every test would pay for it: create one in
  the test, with the context defaults and recorded, and disposed at its end:

      request = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))
  """
  use ExUnit.CaseTemplate
  use Playwright.Test

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Test.BrowserPool

  using opts do
    quote do
      use Playwright.Test, unquote(opts)

      alias Playwright.{Browser, BrowserContext, Expect, Keyboard, Locator, Mouse, Page, Test}
      alias Playwright.Test.BrowserPool
    end
  end

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  setup %{browser: browser} do
    context = Browser.new_context!(browser)
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end
