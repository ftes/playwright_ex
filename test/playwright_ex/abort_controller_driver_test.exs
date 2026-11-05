defmodule PlaywrightEx.AbortControllerDriverTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.AbortError
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestBrowser

  @moduletag timeout: 120_000

  setup_all do
    pages =
      for name <- [Module.concat(__MODULE__, A), Module.concat(__MODULE__, B)] do
        start_supervised!({PlaywrightEx.Supervisor, name: name}, id: name)
        browser = BrowserType.launch!(TestBrowser.browser_type(PlaywrightEx.playwright(name)))
        Browser.new_page!(browser)
      end

    %{pages: pages}
  end

  test "one signal aborts calls on two drivers", %{pages: [a, b]} do
    refute a.conn == b.conn
    controller = AbortController.new()
    signal = AbortController.signal(controller)

    click = fn page ->
      Task.async(fn -> Locator.click(Page.locator(page, "#missing"), signal: signal, timeout: 0) end)
    end

    tasks = [click.(a), click.(b)]

    Process.sleep(500)
    AbortController.abort(controller, "stop")
    assert [{:error, %AbortError{cause: "stop"}}, {:error, %AbortError{cause: "stop"}}] = Task.await_many(tasks)

    # Aborted already: calls on either driver fail at once.
    assert {:error, %AbortError{cause: "stop"}} = Locator.click(Page.locator(a, "#missing"), signal: signal)

    assert {:error, %AbortError{cause: "stop"}} =
             PlaywrightEx.Promise.await(Page.wait_for_event(b, :close, signal: signal))
  end
end
