defmodule PlaywrightEx.Case do
  @moduledoc """
  A case template with Playwright Test's default fixtures: each test gets `browser`, `context`
  and `page`, recorded as the `:test` config says (see `PlaywrightEx.Test`).

      defmodule MyApp.SignUpTest do
        use PlaywrightEx.Case, async: true

        test "signs up", %{page: page} do
          Page.goto!(page, "/sign-up")
          Expect.to_have_title!(page, "Sign up")
        end
      end

  It only puts `PlaywrightEx.Test`'s public pieces together, so it is a recipe as much as an
  API. To add setup that runs after these, `use PlaywrightEx.Case` in your own template's
  `using` and put the setup after it there (a template's own `setup` runs before the ones its
  `using` brings in):

      using do
        quote do
          use PlaywrightEx.Case
          setup %{page: page}, do: MyApp.Auth.log_in(page)
        end
      end

  To change a piece (context options from a tag, a browser you connect to, other
  aliases), copy this module's source into `test/support` and edit it there.
  """
  use ExUnit.CaseTemplate

  import PlaywrightEx.Test, only: [browser: 1, new_context: 1, new_page: 1]

  using do
    quote do
      use PlaywrightEx.Test

      alias PlaywrightEx.{Browser, BrowserContext, Expect, Locator, Page}
    end
  end

  setup_all :browser
  setup [:new_context, :new_page]
end
