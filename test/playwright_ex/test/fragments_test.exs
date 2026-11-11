defmodule PlaywrightEx.Test.FragmentsTest do
  use ExUnit.Case, async: true

  import PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.Options
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
    refute File.exists?(Recorder.output_dir(Options.output_dir(), ctx.file, ctx.test))
  end

  test "new_context passes context_options as is", ctx do
    %{context: context} = new_context(ctx, context_options: [locale: "de-DE", viewport: %{width: 400, height: 300}])
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, "navigator.language") == "de-DE"
    assert Page.viewport_size(page) == %{width: 400, height: 300}
  end

  test "a second browser/1 with other options is another browser", %{browser: browser} do
    %{browser: other} = browser(launch_options: [timeout: 30_001])
    assert other != browser
    assert Browser.is_connected(other)
  end
end

defmodule PlaywrightEx.Test.UserBrowserTest do
  # A `setup_all` of the user's own makes `%{browser: _}`; the other fragments take it.
  use ExUnit.Case, async: true

  import PlaywrightEx.Test

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.TestBrowser

  setup_all %{module: module} do
    start_supervised!({PlaywrightEx.Supervisor, name: module})
    %{browser: BrowserType.launch!(TestBrowser.browser_type(PlaywrightEx.playwright(module)))}
  end

  # Registered first, so it runs after the recording's `on_exit`.
  setup ctx do
    dir = Recorder.output_dir(Options.output_dir(), ctx.file, ctx.test)

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
