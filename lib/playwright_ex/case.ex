defmodule PlaywrightEx.Case do
  @moduledoc """
  A case template with Playwright Test's default fixtures: each test gets a `context` of the
  shared browser (`PlaywrightEx.Test.BrowserPool.shared/1`) and a `page` of it, recorded as the
  `:test` config and the test's tags say (see `PlaywrightEx.Test`).

      defmodule MyApp.SignUpTest do
        use PlaywrightEx.Case, async: true

        test "signs up", %{page: page} do
          Page.goto!(page, "/sign-up")
          Expect.to_have_title!(page, "Sign up")
        end
      end

  It only puts the pieces together, so it is a recipe as much as an API: `use PlaywrightEx.Test`
  first in the body, so the test is registered before the context is created, then the
  context and page from the plain API. To add setup that runs after these, `use
  PlaywrightEx.Case` in your own template's `using` and put the setup after it there (a
  template's own `setup` runs before the ones its `using` brings in):

      using do
        quote do
          use PlaywrightEx.Case
          setup %{page: page}, do: MyApp.Auth.log_in(page)
        end
      end

  To change a piece (another browser, context options from a tag, other aliases), copy this
  module's source into `test/support` and edit it there.
  """
  use ExUnit.CaseTemplate
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Test.BrowserPool

  using do
    quote do
      use PlaywrightEx.Test

      alias PlaywrightEx.{Browser, BrowserContext, Expect, Locator, Page, Test}
      alias PlaywrightEx.Test.BrowserPool
    end
  end

  setup do
    context = Browser.new_context!(BrowserPool.shared())
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end
