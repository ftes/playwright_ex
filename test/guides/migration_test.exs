defmodule PlaywrightEx.Guides.MigrationTest do
  # The snippets of `guides/migration.md`, run against the facade.
  use ExUnit.Case, async: true

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.AbortError
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Download
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.Selectors
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.TimeoutError
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.WebError

  @moduletag :tmp_dir

  # The doctype keeps firefox from logging a quirks-mode warning to the console.
  @html """
  <!doctype html>
  <title>Home</title>
  <form><label>Email <input name="email"></label>
  <select name="role"><option>user</option><option>admin</option></select>
  <label><input type="checkbox" name="tos"> Accept</label>
  <input type="file" name="avatar"></form>
  <button onclick="document.querySelector('.flash').hidden = false">Delete</button>
  <p class="flash" hidden>Deleted</p>
  <a href="data:text/csv,a%2Cb" download="report.csv">Export</a>
  <a href="/popup" target="_blank">Open</a>
  """

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    playwright = PlaywrightEx.playwright(__MODULE__)
    browser = BrowserType.launch!(TestBrowser.browser_type(playwright))
    %{playwright: playwright, browser: browser}
  end

  setup %{browser: browser} do
    context = Browser.new_context!(browser, base_url: "http://app.test", locale: "en")
    BrowserContext.set_default_timeout(context, 5_000)
    on_exit(fn -> BrowserContext.close(context) end)

    {:ok, _} =
      BrowserContext.route(context, "http://app.test/**", fn route, request ->
        case URI.parse(Request.url(request)).path do
          "/report.csv" ->
            Route.fulfill(route,
              body: "a,b",
              content_type: "application/octet-stream",
              headers: %{"content-disposition" => "attachment"}
            )

          _ ->
            Route.fulfill(route, body: @html, content_type: "text/html")
        end
      end)

    page = BrowserContext.new_page!(context)
    %{context: context, page: page}
  end

  test "navigation and locators", %{page: page} do
    response = Page.goto!(page, "/")
    assert Response.status(response) == 200
    assert Page.url(page) == "http://app.test/"
    assert Page.title!(page) == "Home"

    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_label(page, "Email") |> Locator.press!("Tab")
    Page.locator(page, "select[name=role]") |> Locator.select_option!("admin")
    Page.get_by_label(page, "Accept") |> Locator.check!()
    Page.get_by_role(page, :button, name: "Delete") |> Locator.click!()

    Expect.to_be_visible!(Page.locator(page, ".flash") |> Locator.filter(has_text: "Deleted"))
    Expect.to_have_title!(page, "Home")
    Expect.to_have_url!(page, ~r"/$")
    Expect.to_have_count!(Page.locator(page, "label"), 2)
    Expect.to_have_value!(Page.get_by_label(page, "Email"), "ada@example.com")
    assert {:error, %{message: message}} = Expect.to_have_title(page, "Nope", timeout: 100)
    assert message =~ "toHaveTitle"
    Page.wait_for_load_state!(page, timeout: 1_000)
    Expect.not_to_have_attribute!(Page.get_by_label(page, "Email"), "disabled", timeout: 1_000)
    Expect.not_to_have_text!(Page.locator(page, ".flash"), "x")
    Page.locator(page, ".flash") |> Expect.not_() |> Expect.to_have_text!("x")

    assert Page.locator(page, "css=.flash >> internal:text=\"Deleted\"i") |> Locator.count!() == 1

    file = Path.join(System.tmp_dir!(), "migration_guide_avatar.txt")
    File.write!(file, "x")
    Page.locator(page, "input[type=file]") |> Locator.set_input_files!(file)

    Page.locator(page, "input[type=file]")
    |> Locator.set_input_files!(%{name: "a.txt", mimeType: "text/plain", buffer: "hello"})

    Mouse.move!(Page.mouse(page), 10, 10)
  end

  test "mapping tables", %{context: context, page: page} do
    Page.goto!(page, "/")
    Page.wait_for_url!(page, "**/")
    assert Page.locator(page, "form") |> Locator.locator("select") |> Locator.count!() == 1
    assert Page.locator(page, "a") |> Locator.nth(1) |> Locator.text_content!() == "Open"
    assert Page.locator(page, "a") |> Locator.first() |> Locator.text_content!() == "Export"
    assert Page.locator(page, "p") |> Locator.filter(visible: true) |> Locator.count!() == 0

    assert Page.locator(page, "label")
           |> Locator.filter(has: Page.locator(page, "input[name=email]"))
           |> Locator.count!() == 1

    assert Page.get_by_text(page, "delete", exact: false)
           |> Locator.and_(Page.locator(page, "button"))
           |> Locator.count!() == 1

    Page.get_by_label(page, "Email") |> Locator.press_sequentially!("ab")
    Page.get_by_label(page, "Email") |> Locator.wait_for!()
    Page.get_by_label(page, "Email") |> Locator.blur!()
    Page.get_by_role(page, :link, name: "Open") |> Locator.drag_to!(Page.get_by_role(page, :button, name: "Delete"))
    assert Page.get_by_label(page, "Email") |> Locator.input_value!() == "ab"
    Page.get_by_label(page, "Accept") |> Locator.set_checked!(false)

    chooser = Page.expect_file_chooser!(page, fn -> Locator.click!(Page.locator(page, "input[type=file]")) end)
    PlaywrightEx.FileChooser.set_files!(chooser, %{name: "a.txt", mimeType: "text/plain", buffer: "x"})

    PlaywrightEx.Clock.install!(BrowserContext.clock(context))
    PlaywrightEx.Clock.fast_forward!(BrowserContext.clock(context), 1000)
  end

  test "js logger recipe", %{context: context, page: page} do
    owner = self()
    BrowserContext.on(context, :console, &send(owner, {:console, &1}))
    BrowserContext.on(context, :web_error, &send(owner, {:web_error, &1}))
    Page.goto!(page, "/")
    Page.evaluate!(page, "() => { console.log('hi'); setTimeout(() => { throw new Error('boom') }) }")
    assert_receive {:console, msg}
    assert %{url: _, lineNumber: _} = ConsoleMessage.location(msg)
    assert "#{ConsoleMessage.text(msg)} #{ConsoleMessage.type(msg)}" == "hi log"
    assert_receive {:web_error, error}
    assert Exception.message(WebError.error(error)) == "boom"
  end

  test "evaluate", %{page: page} do
    Page.goto!(page, "/")
    assert Page.evaluate!(page, "() => window.location.pathname") == "/"
    assert Page.evaluate!(page, "document.title") == "Home"
    assert Page.evaluate!(page, "([a, b]) => a + b", [1, 2]) == 3
    assert Page.locator(page, "button") |> Locator.evaluate!("el => el.textContent") == "Delete"
  end

  test "events: listeners send to the owner", %{context: context, page: page} do
    owner = self()

    Page.on(page, :console, fn msg ->
      send(owner, {:console, ConsoleMessage.type(msg), ConsoleMessage.text(msg), ConsoleMessage.location(msg)})
    end)

    BrowserContext.on(context, :web_error, fn web_error ->
      send(owner, {:web_error, Exception.message(WebError.error(web_error))})
    end)

    Page.goto!(page, "/")
    Page.evaluate!(page, "() => console.warn('hi')")
    assert_receive {:console, "warning", "hi", %{url: _, lineNumber: _}}

    Page.evaluate!(page, "() => setTimeout(() => { throw new Error('boom') })")
    assert_receive {:web_error, "boom"}
  end

  test "promises and expect_* callbacks", %{page: page, tmp_dir: tmp_dir} do
    Page.goto!(page, "/")

    popup = Page.wait_for_event(page, :popup)
    Page.get_by_text(page, "Open") |> Locator.click!()
    assert %PlaywrightEx.Page{} = Promise.await!(popup)

    {:ok, popup} = Page.expect_popup(page, fn -> Page.get_by_text(page, "Open") |> Locator.click!() end)
    assert Page.url(popup) == "http://app.test/popup"

    ready = Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) == "ready"))
    Page.evaluate!(page, "() => { console.log('not yet'); console.log('ready') }")
    assert ConsoleMessage.text(Promise.await!(ready)) == "ready"

    log_ready = fn -> Page.evaluate!(page, "() => { console.log('not yet'); console.log('ready') }") end
    message = Page.expect_event!(page, :console, log_ready, &(ConsoleMessage.text(&1) == "ready"))

    assert ConsoleMessage.text(message) == "ready"

    Page.evaluate!(page, "() => { setTimeout(() => console.log('later'), 100) }")
    assert ConsoleMessage.text(Page.wait_for_event!(page, :console)) == "later"

    download = Page.expect_download!(page, fn -> Page.get_by_text(page, "Export") |> Locator.click!() end)
    assert Download.suggested_filename(download) == "report.csv"
    :ok = Download.save_as(download, Path.join(tmp_dir, "report.csv"))
    assert File.read!(Path.join(tmp_dir, "report.csv")) == "a,b"

    request = Page.expect_request!(page, "**/api/data", fn -> Page.evaluate!(page, "() => fetch('/api/data')") end)
    assert Response.status(Request.response!(request)) == 200
  end

  test "dialogs", %{page: page} do
    Page.goto!(page, "/")
    # No listener: auto-dismissed.
    assert Page.evaluate!(page, "() => confirm('Sure?')") == false

    owner = self()

    handler = fn dialog ->
      send(owner, {:dialog, Dialog.message(dialog)})
      Dialog.accept(dialog, "42")
    end

    Page.on(page, :dialog, handler)
    assert Page.evaluate!(page, "() => prompt('Magic number?')") == "42"
    assert_received {:dialog, "Magic number?"}
    Page.off(page, :dialog, handler)
  end

  test "routing", %{page: page} do
    Page.route!(page, "**/api/profile", fn route -> Route.fulfill(route, json: %{name: "Ada"}) end)
    Page.route!(page, "**/*.png", &Route.abort/1)
    Page.goto!(page, "/")
    assert Page.evaluate!(page, "() => fetch('/api/profile').then(r => r.json())") == %{"name" => "Ada"}
    :ok = Page.unroute!(page, "**/api/profile")
  end

  test "tracing and screenshots", %{context: context, page: page, tmp_dir: tmp_dir} do
    tracing = BrowserContext.tracing(context)
    Tracing.start!(tracing, screenshots: true, snapshots: true)
    Tracing.start_chunk!(tracing)

    Tracing.group!(tracing, "sign in", location: %{file: __ENV__.file, line: __ENV__.line})
    Page.goto!(page, "/")
    Tracing.group_end!(tracing)

    path = Path.join(tmp_dir, "trace.zip")
    Tracing.stop_chunk!(tracing, path: path)
    Tracing.stop!(tracing)
    assert File.exists?(path)

    assert <<0x89, "PNG", _::binary>> = Page.screenshot!(page, full_page: true)
    Page.screenshot!(page, path: Path.join(tmp_dir, "page.png"))
    :ok = Expect.to_have_screenshot!(Page.locator(page, "button"), path: Path.join(tmp_dir, "button.png"))
  end

  test "cookies", %{context: context} do
    BrowserContext.add_cookies!(context, [%{name: "session", value: "abc", url: "http://app.test"}])
    assert [%{name: "session", value: "abc"}] = BrowserContext.cookies!(context)
    BrowserContext.clear_cookies!(context)
    assert BrowserContext.cookies!(context) == []
  end

  test "selector engines", %{playwright: playwright, browser: browser} do
    script =
      "({ query: (root, s) => root.querySelector(`[name=${s}]`), queryAll: (root, s) => [...root.querySelectorAll(`[name=${s}]`)] })"

    Selectors.register!(Playwright.selectors(playwright), "named", %{content: script})
    page = Browser.new_page!(browser)
    Page.set_content!(page, ~s(<input name="email">))
    assert Page.locator(page, "named=email") |> Locator.count!() == 1
    Page.close!(page)
  end

  test "errors and timeouts", %{page: page} do
    Page.goto!(page, "/")
    assert {:error, %TimeoutError{} = error} = Page.locator(page, "#missing") |> Locator.click(timeout: 100)
    assert error.message =~ ~r/^locator\.click: Timeout 100ms exceeded/
    assert is_list(error.log)

    assert_raise TimeoutError, fn -> Page.locator(page, "#missing") |> Locator.click!(timeout: 100) end

    assert_raise ArgumentError, ~r/unknown option :timout/, fn -> Page.goto(page, "/", timout: 1) end
  end

  test "bounding calls without a timeout", %{page: page} do
    task = Task.async(fn -> Page.close(page) end)
    assert {:ok, :ok} = Task.yield(task, 5_000) || Task.shutdown(task)
  end

  test "cancelling a call with a signal", %{page: page} do
    controller = AbortController.new()

    Task.start(fn ->
      Process.sleep(1_000)
      AbortController.abort(controller, "user cancelled")
    end)

    {:error, %AbortError{cause: "user cancelled"}} =
      Page.locator(page, "#x") |> Locator.click(signal: AbortController.signal(controller), timeout: 0)
  end
end
