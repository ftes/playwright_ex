defmodule Playwright.AbortControllerDriverTest do
  use ExUnit.Case, async: true

  alias Playwright.AbortController
  alias Playwright.AbortError
  alias Playwright.Browser
  alias Playwright.BrowserType
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.TestBrowser

  setup_all do
    pages =
      for name <- [Module.concat(__MODULE__, A), Module.concat(__MODULE__, B)] do
        start_supervised!({Playwright.Supervisor, name: name}, id: name)
        browser = BrowserType.launch!(TestBrowser.browser_type(Playwright.instance(name)))
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
             Playwright.Promise.await(Page.wait_for_event(b, :close, signal: signal))
  end
end
