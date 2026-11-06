defmodule PlaywrightEx.Guides.CheatsheetTest do
  # The Elixir snippets of `guides/introduction/cheatsheet.cheatmd`, against a local server.
  # Files the cheatsheet writes to the working directory go to the test's tmp dir here.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Logger

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Download
  alias PlaywrightEx.Expect
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.TestServer

  @moduletag :tmp_dir

  @html """
  <title>Dashboard</title>
  <h1>Welcome</h1>
  <nav><a href="/home">Home</a> <a href="/login">Login</a></nav>
  <button data-testid="submit">Sign in</button>
  <label>Email <input name="email" placeholder="name@example.com"></label>
  <label><input type="checkbox"> Accept</label>
  <select><option>red</option><option>blue</option></select>
  <input type="file">
  <ul><li>Apple</li><li>Banana</li><li>Cherry</li></ul>
  <p class="flash">Saved</p>
  <p class="hidden" hidden>Hidden</p>
  <iframe id="editor" srcdoc="<textarea></textarea>"></iframe>
  <a href="/popup" target="_blank">Open</a>
  <a href="/report.csv" download>Export</a>
  <button onclick="fetch('/api/user')">Load</button>
  <script>window.ready = true</script>
  """

  setup_all do
    server = TestServer.create(System.tmp_dir!())
    on_exit(fn -> TestServer.stop(server) end)

    for path <- ~w(/ /login /dashboard /popup), do: TestServer.set_content(server, path, @html, "text/html")
    TestServer.set_content(server, "/report.csv", "a,b", "text/csv")
    TestServer.set_content(server, "/api/user", ~s({"name":"Ada"}), "application/json")

    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    playwright = PlaywrightEx.playwright(__MODULE__)
    %{server: server, playwright: playwright}
  end

  setup %{server: server, playwright: playwright} do
    # The cheatsheet launches `Playwright.chromium()` with a `base_url` of localhost:4000.
    browser = playwright |> TestBrowser.browser_type() |> BrowserType.launch!()
    context = Browser.new_context!(browser, base_url: server.prefix)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/")
    on_exit(fn -> Browser.close(browser) end)
    %{browser: browser, context: context, page: page}
  end

  test "setup", %{browser: browser, context: context} do
    BrowserContext.close!(context)
    Browser.close!(browser)
  end

  test "navigation", %{page: page, server: server} do
    Page.goto!(page, "/login")
    Page.go_back!(page)
    Page.go_forward!(page)
    Page.reload!(page)
    assert Page.url(page) == server.prefix <> "/login"
    assert Page.title!(page) == "Dashboard"
    Page.goto!(page, "/dashboard")
    Page.wait_for_url!(page, "**/dashboard")
  end

  test "locators", %{page: page} do
    for locator <- [
          Page.get_by_role(page, :button, name: "Sign in"),
          Page.get_by_label(page, "Email"),
          Page.get_by_placeholder(page, "name@example.com"),
          Page.get_by_text(page, "Welcome", exact: true),
          Page.get_by_test_id(page, "submit"),
          Page.locator(page, ".flash"),
          Page.get_by_role(page, :listitem) |> Locator.filter(has_text: "Apple"),
          Page.get_by_role(page, :listitem) |> Locator.nth(1),
          Page.get_by_role(page, :listitem) |> Locator.first(),
          Page.frame_locator(page, "#editor") |> FrameLocator.get_by_role(:textbox)
        ] do
      assert Locator.count!(locator) == 1
    end

    assert Page.locator(page, "nav") |> Locator.get_by_role(:link) |> Locator.count!() == 2
    assert Page.get_by_role(page, :listitem) |> Locator.count!() == 3

    output =
      capture_io(fn ->
        for item <- Page.get_by_role(page, :listitem) |> Locator.all!() do
          IO.puts(Locator.text_content!(item))
        end
      end)

    assert output == "Apple\nBanana\nCherry\n"
  end

  test "actions", %{page: page, tmp_dir: tmp_dir} do
    locator = Page.get_by_label(page, "Email")
    Locator.click!(locator)
    Locator.dblclick!(locator)
    Locator.fill!(locator, "ada@example.com")
    Locator.press!(locator, "Enter")
    Locator.clear!(locator)
    Locator.press_sequentially!(locator, "hello")
    assert Locator.input_value!(locator) == "hello"

    locator = Page.get_by_label(page, "Accept")
    Locator.check!(locator)
    Locator.uncheck!(locator)

    locator = Page.locator(page, "select")
    Locator.select_option!(locator, "blue")
    assert Locator.input_value!(locator) == "blue"

    locator = Page.locator(page, "input[type=file]")
    avatar = Path.join(tmp_dir, "avatar.png")
    File.write!(avatar, "png")
    Locator.set_input_files!(locator, avatar)

    locator = Page.get_by_text(page, "Apple")
    target = Page.get_by_text(page, "Cherry")
    Locator.hover!(locator)
    Locator.drag_to!(locator, target)
    Page.keyboard(page) |> Keyboard.press!("Control+A")
    Page.mouse(page) |> Mouse.click!(10, 10)

    locator = Page.get_by_role(page, :link, name: "Home")
    assert Locator.text_content!(locator) == "Home"
    assert Locator.inner_text!(locator) == "Home"
    assert Locator.get_attribute!(locator, "href") == "/home"
    assert Locator.is_visible!(locator)
    assert Page.get_by_label(page, "Email") |> Locator.input_value!() == "hello"
  end

  test "assertions", %{page: page} do
    locator = Page.get_by_role(page, :heading)
    Expect.to_be_visible!(locator)
    Expect.to_have_text!(locator, "Welcome")
    Expect.to_contain_text!(locator, "Wel")

    locator = Page.get_by_label(page, "Email")
    Locator.fill!(locator, "ada@example.com")
    Expect.to_have_value!(locator, "ada@example.com")

    Expect.to_have_count!(Page.get_by_role(page, :listitem), 3)

    locator = Page.get_by_label(page, "Accept")
    Locator.check!(locator)
    Expect.to_be_checked!(locator)

    Expect.to_have_attribute!(Page.get_by_role(page, :link, name: "Home"), "href", "/home")

    Page.goto!(page, "/dashboard")
    Expect.to_have_title!(page, ~r/Dashboard/)
    Expect.to_have_url!(page, "/dashboard")

    Expect.not_to_be_visible!(Page.locator(page, ".hidden"))
    Expect.to_be_visible!(Page.locator(page, ".flash"), timeout: 10_000)
  end

  test "waiting", %{page: page, tmp_dir: tmp_dir} do
    popup =
      Page.expect_popup!(page, fn ->
        Page.get_by_text(page, "Open") |> Locator.click!()
      end)

    assert Page.url(popup) =~ "/popup"

    download =
      Page.expect_download!(page, fn ->
        Page.get_by_text(page, "Export") |> Locator.click!()
      end)

    path = Path.join(tmp_dir, "report.csv")
    Download.save_as!(download, path)
    assert File.read!(path) == "a,b"

    Locator.wait_for!(Page.locator(page, ".hidden"), state: :hidden)
    Page.wait_for_load_state!(page, :networkidle)
    Page.wait_for_function!(page, "() => window.ready")
  end

  test "listeners", %{page: page} do
    Page.on(page, :console, &Logger.info(ConsoleMessage.text(&1)))
    Page.on(page, :dialog, &Dialog.accept/1)

    assert capture_log(fn -> Page.evaluate!(page, "() => console.log('hi')") end) =~ "hi"
    assert Page.evaluate!(page, "() => confirm('Sure?')") == true
  end

  test "network", %{page: page, server: server} do
    Page.route!(page, "**/api/user", &Route.fulfill(&1, json: %{name: "Ada"}))
    Page.route!(page, "**/*.png", &Route.abort/1)
    assert Page.evaluate!(page, "() => fetch('/api/user').then(r => r.json())") == %{"name" => "Ada"}
    assert Page.evaluate!(page, "() => fetch('/a.png').then(() => 'ok', () => 'blocked')") == "blocked"
    Page.unroute_all!(page)

    Page.route!(page, "**/api/**", fn route, request ->
      headers = Map.put(Request.headers(request), "x-test", "1")
      Route.continue(route, headers: headers)
    end)

    received = TestServer.wait_for_request(server, "/api/user")

    response =
      Page.expect_response!(page, "**/api/user", fn ->
        Page.get_by_text(page, "Load") |> Locator.click!()
      end)

    assert Response.json!(response) == %{"name" => "Ada"}
    assert Plug.Conn.get_req_header(Task.await(received), "x-test") == ["1"]

    response = Page.request(page) |> APIRequestContext.get!("/api/user")
    Expect.to_be_ok!(response)
    assert APIResponse.json!(response) == %{"name" => "Ada"}
  end

  test "screenshots and evaluate", %{page: page, tmp_dir: tmp_dir} do
    Page.screenshot!(page, path: Path.join(tmp_dir, "page.png"), full_page: true)
    locator = Page.get_by_role(page, :button, name: "Sign in")
    Locator.screenshot!(locator, path: Path.join(tmp_dir, "button.png"))
    assert <<0x89, "PNG", _::binary>> = Page.screenshot!(page)
    assert File.exists?(Path.join(tmp_dir, "page.png")) and File.exists?(Path.join(tmp_dir, "button.png"))

    assert Page.evaluate!(page, "() => document.title") == "Dashboard"
    assert Page.evaluate!(page, "([a, b]) => a + b", [1, 2]) == 3
    assert Locator.evaluate!(locator, "el => el.textContent") == "Sign in"
  end
end
