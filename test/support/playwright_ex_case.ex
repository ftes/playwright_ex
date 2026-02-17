defmodule PlaywrightExCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  @timeout Application.compile_env(:playwright_ex, :timeout)

  using(_opts) do
    quote do
      import PlaywrightExCase

      @timeout unquote(@timeout)
    end
  end

  setup do
    {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: @timeout)
    {:ok, browser_context} = PlaywrightEx.Browser.new_context(browser.guid, timeout: @timeout)
    {:ok, page} = PlaywrightEx.BrowserContext.new_page(browser_context.guid, timeout: @timeout)
    ExUnit.Callbacks.on_exit(fn -> PlaywrightEx.Browser.close(browser.guid, timeout: @timeout) end)

    [browser: browser, browser_context: browser_context, page: page, frame: page.main_frame]
  end

  def set_html(frame_id, html) do
    {:ok, _} = PlaywrightEx.Frame.goto(frame_id, url: "about:blank", timeout: @timeout)
    {:ok, _} = eval(frame_id, "(html) => { document.body.innerHTML = html; }", html)
    :ok
  end

  def eval(frame_id, expression, arg \\ nil) do
    PlaywrightEx.Frame.evaluate(frame_id,
      expression: expression,
      is_function: true,
      arg: arg,
      timeout: @timeout
    )
  end

  def assert_has(frame_id, selector) do
    assert_expect(frame_id, selector, invert: false)
  end

  def refute_has(frame_id, selector) do
    assert_expect(frame_id, selector, invert: true)
  end

  def assert_expect(frame_id, selector, invert: invert?) do
    opts = [selector: selector, is_not: invert?, expression: "to.be.visible", timeout: @timeout]
    {:ok, result} = PlaywrightEx.Frame.expect(frame_id, opts)
    assert result != invert?, "expected#{if invert?, do: " not"} to find #{selector}"
  end
end
