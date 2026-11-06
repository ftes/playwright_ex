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
  navigate stay offline). Contexts the example creates itself, of `browser` or of a browser it
  launches, are routed the same. Options:

    * `:js` - the upstream JS block, as api.json has it (required).
    * `:html` - the document every request gets, default an empty page.
    * `:given` - bindings the docs leave out, e.g. `given: [frame: Page.main_frame(page)]`.
    * `:skip` - why the example only compiles (it needs the network, say).
    * `:writes` - files the example writes to the working directory (`path: "link.png"`),
      removed after it.

  A body that is one `test "name", %{page: page} do ... end` (upstream's test-runner examples)
  runs that block, its pattern matched against those four. Output (`IO.puts`) is captured.
  """
  use ExUnit.CaseTemplate

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.ClientInstrumentation
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.TestBrowser

  @html "<!doctype html><title>Example</title>"

  using do
    quote do
      import PlaywrightEx.ExampleCase, only: [example: 3]

      # The docs' examples use the short names.
      alias PlaywrightEx.{Browser, BrowserContext, BrowserType, Expect, Frame, FrameLocator, Keyboard, Locator, Mouse}
      alias PlaywrightEx.{Page, Playwright, Request, Response, Route, Selectors}
    end
  end

  setup_all context do
    name = Module.concat(context.module, Playwright)
    start_supervised!({PlaywrightEx.Supervisor, name: name})
    playwright = PlaywrightEx.playwright(name)
    browser = BrowserType.launch!(TestBrowser.browser_type(playwright))
    %{playwright: playwright, browser: browser}
  end

  setup %{playwright: playwright, browser: browser} = tags do
    context = Browser.new_context!(browser)
    BrowserContext.set_default_timeout(context, 5_000)
    on_exit(fn -> BrowserContext.close(context) end)
    for path <- Map.get(tags, :writes) || [], do: on_exit(fn -> File.rm(path) end)
    html = Map.get(tags, :html) || @html
    fulfill = &Route.fulfill(&1, body: html, content_type: "text/html")
    offline = &BrowserContext.route!(&1, "**/*", fulfill)
    offline.(context)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://example.com/")
    # The contexts the example creates (`Browser.new_context`, a browser of its own).
    instrumentation = Heap.get(playwright, :_instrumentation)
    listener = %{runAfterCreateBrowserContext: offline}
    ClientInstrumentation.add_listener(instrumentation, listener)
    on_exit(fn -> ClientInstrumentation.remove_listener(instrumentation, listener) end)
    %{context: context, page: page}
  end

  defmacro example(member, opts, do: body) do
    js = Keyword.fetch!(opts, :js)
    bindings = for {var, expr} <- Keyword.get(opts, :given, []), do: {:=, [], [Macro.var(var, nil), expr]}

    # A body that is one ExUnit test (upstream's `test('...', async ({ page }) => ...)`) runs its
    # block, its context pattern matched against the example's context.
    body =
      case body do
        {:test, _, [name, pattern, [do: block]]} when is_binary(name) ->
          quote do
            unquote(pattern) = %{
              playwright: var!(playwright),
              browser: var!(browser),
              context: var!(context),
              page: var!(page)
            }

            unquote(block)
          end

        body ->
          body
      end

    quote do
      @tag html: unquote(opts[:html])
      @tag writes: unquote(opts[:writes])
      if reason = unquote(opts[:skip]), do: @tag(skip: reason)

      # The first line of the JS: a whole block can exceed the atom limit of the test's funs.
      test "#{unquote(member)} (line #{__ENV__.line}): #{unquote(js) |> String.split("\n") |> hd()}", %{
        playwright: var!(playwright),
        browser: var!(browser),
        context: var!(context),
        page: var!(page)
      } do
        _ = {var!(playwright), var!(browser), var!(context), var!(page)}

        ExUnit.CaptureIO.capture_io(fn ->
          unquote_splicing(bindings)
          unquote(body)
          # The docs bind results they don't use (`texts = ...`).
          _ = binding()
        end)
      end
    end
  end
end
