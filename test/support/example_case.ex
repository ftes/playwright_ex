defmodule PlaywrightEx.ExampleCase do
  @moduledoc """
  Case template for the Elixir translations of the facade docs' JS examples (`test/examples`).

      example "Locator.click", js: ~S\"""
      await page.getByRole('button').click();
      \""", html: "<button>Go</button>" do
        Page.get_by_role(page, :button) |> Locator.click!()
      end

  Each `example` is a test, and `mix playwright_ex.gen.api` renders its body (the source between
  `do` and `end`, see `Mix.PlaywrightEx.Examples`) in place of the upstream block equal to `js:`.
  So a translation compiles and runs before it is shown, and an upstream change to the JS leaves a
  stale example the generator reports.

  The body sees `playwright`, `browser`, `context` and `page` (`page` has loaded `html:` from
  `https://example.com/`: every request of the context is fulfilled with it, so examples that
  navigate stay offline). Options:

    * `:js` - the upstream JS block, as api.json has it (required).
    * `:html` - the document every request gets, default an empty page.
    * `:given` - bindings the docs leave out, e.g. `given: [frame: Page.main_frame(page)]`.
    * `:skip` - why the example only compiles (it needs the network, say).

  Output (`IO.puts`) is captured.
  """
  use ExUnit.CaseTemplate

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestBrowser

  @html "<!doctype html><title>Example</title>"

  using do
    quote do
      import PlaywrightEx.ExampleCase, only: [example: 3]

      # The docs' examples use the short names.
      alias PlaywrightEx.{Browser, BrowserContext, BrowserType, Expect, Frame, Keyboard, Locator, Mouse}
      alias PlaywrightEx.{Page, Playwright, Request, Response, Route}
    end
  end

  setup_all context do
    name = Module.concat(context.module, Playwright)
    start_supervised!({PlaywrightEx.Supervisor, name: name})
    playwright = PlaywrightEx.playwright(name)
    browser = BrowserType.launch!(TestBrowser.browser_type(playwright))
    %{playwright: playwright, browser: browser}
  end

  setup %{browser: browser} = tags do
    context = Browser.new_context!(browser)
    BrowserContext.set_default_timeout(context, 5_000)
    on_exit(fn -> BrowserContext.close(context) end)
    html = Map.get(tags, :html) || @html
    BrowserContext.route!(context, "**/*", &Route.fulfill(&1, body: html, content_type: "text/html"))
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://example.com/")
    %{context: context, page: page}
  end

  defmacro example(member, opts, do: body) do
    js = Keyword.fetch!(opts, :js)
    bindings = for {var, expr} <- Keyword.get(opts, :given, []), do: {:=, [], [Macro.var(var, nil), expr]}

    quote do
      @tag html: unquote(opts[:html])
      if reason = unquote(opts[:skip]), do: @tag(skip: reason)

      test "#{unquote(member)}: #{unquote(js)}", %{
        playwright: var!(playwright),
        browser: var!(browser),
        context: var!(context),
        page: var!(page)
      } do
        _ = {var!(playwright), var!(browser), var!(context), var!(page)}

        ExUnit.CaptureIO.capture_io(fn ->
          unquote_splicing(bindings)
          unquote(body)
        end)
      end
    end
  end
end
