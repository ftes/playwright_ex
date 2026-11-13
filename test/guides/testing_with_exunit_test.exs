# The snippets of `guides/testing-with-exunit.md`, run against an app on `PlaywrightEx.TestServer`.
# Deviations from the guide: each module starts its own app, and the browser is `BROWSER`'s.

defmodule PlaywrightEx.Guides.TestingWithExUnit.App do
  @moduledoc false
  alias PlaywrightEx.TestServer

  @pages %{
    "/sign-up" => """
    <label>Email <input id="email"></label>
    <button onclick="document.querySelector('[role=status]').textContent = 'Welcome, ' + email.value">Sign up</button>
    <p role="status"></p>
    """,
    "/login" => """
    <label>Email <input></label><label>Password <input type="password"></label>
    <button onclick="document.cookie = 'session=ada; path=/'; localStorage.setItem('theme', 'dark'); location.href = '/dashboard'">Log in</button>
    """,
    "/dashboard" => """
    <ul><li>One</li><li>Two</li><li>Three</li></ul>
    <p>Saved</p><p class="error" hidden>Oops</p>
    <button onclick="console.log('saved')">Save</button>
    """
  }

  def start!(dir) do
    File.mkdir_p!(dir)
    server = TestServer.server(ExUnit.Callbacks.start_supervised!({TestServer, dir_path: dir}))
    TestServer.set_content(server, "/sign-up", @pages["/sign-up"], "text/html")
    TestServer.set_content(server, "/login", @pages["/login"], "text/html")

    TestServer.set_route(server, "/dashboard", fn conn ->
      case Plug.Conn.fetch_cookies(conn).cookies do
        %{"session" => "ada"} -> html(conn, @pages["/dashboard"])
        _ -> conn |> Plug.Conn.put_resp_header("location", "/login") |> Plug.Conn.send_resp(302, "")
      end
    end)

    # A background export: done on the third poll.
    {:ok, polls} = Agent.start_link(fn -> 0 end)

    TestServer.set_route(server, "/api/exports/1", fn conn ->
      status = if Agent.get_and_update(polls, &{&1 + 1, &1 + 1}) >= 3, do: "done", else: "pending"

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(%{status: status}))
    end)

    server
  end

  defp html(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/html")
    |> Plug.Conn.send_resp(200, "<!doctype html>" <> body)
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.BrowserCase do
  @moduledoc false
  # The guide's case template from the pieces. Deviation: `base_url` is the module's own app,
  # not the config's.
  use ExUnit.CaseTemplate
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Guides.TestingWithExUnit.App
  alias PlaywrightEx.Test.BrowserPool

  using do
    quote do
      use PlaywrightEx.Test
      alias PlaywrightEx.{Browser, BrowserContext, Expect, Locator, Page, Test}
      alias PlaywrightEx.Test.BrowserPool
    end
  end

  setup_all do
    server = App.start!(Path.join(System.tmp_dir!(), "guide-app-#{System.unique_integer([:positive])}"))
    %{base_url: server.prefix, browser: BrowserPool.browser()}
  end

  # `@tag locale: "de-DE"` on a test.
  setup %{browser: browser} = ctx do
    options = [base_url: ctx.base_url] ++ Enum.to_list(Map.take(ctx, [:locale]))
    context = Browser.new_context!(browser, options)
    BrowserContext.set_default_timeout(context, 5_000)
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.Assertions do
  @moduledoc false
  @doc "Runs `fun`, re-raising a failed matcher as an `ExUnit.AssertionError`."
  def assert_expect(fun) do
    fun.()
  rescue
    e in PlaywrightEx.ExpectError ->
      reraise ExUnit.AssertionError, [message: Exception.message(e)], __STACKTRACE__
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.SignUpTest do
  use PlaywrightEx.Guides.TestingWithExUnit.BrowserCase, async: true

  alias PlaywrightEx.Guides.TestingWithExUnit.Assertions

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
    Expect.to_have_text!(Page.get_by_role(page, :status), "Welcome, ada@example.com")
  end

  @tag locale: "de-DE"
  test "a tag of the case template", %{page: page} do
    assert Page.evaluate!(page, "navigator.language") == "de-DE"
  end

  # Deviation: the second browser is `BROWSER`'s too (CI installs one browser per job), launched
  # with other options.
  test "two users edit one document", %{browser: browser} do
    ada = Browser.new_context!(browser)
    bob = Browser.new_context!(browser)
    other = BrowserPool.browser(launch_options: [slow_mo: 1])
    eve = Browser.new_context!(other)

    ada_page = BrowserContext.new_page!(ada)
    bob_page = BrowserContext.new_page!(bob)
    eve_page = BrowserContext.new_page!(eve)
    assert BrowserContext.browser(eve) == other
    # Another worker, held by the module over `workers`.
    assert BrowserPool.playwright(other) != BrowserPool.playwright(browser)
    for page <- [ada_page, bob_page, eve_page], do: Page.set_content!(page, "<p>Doc</p>")
  end

  # "Devices". Deviation: the browser is `BROWSER`'s.
  test "on a phone" do
    alias PlaywrightEx.Playwright
    browser = BrowserPool.browser()
    iphone = Playwright.devices(BrowserPool.playwright(browser))["iPhone 13"]
    page = BrowserContext.new_page!(Browser.new_context!(browser, Map.put(iphone, :locale, "de-DE")))
    assert iphone.default_browser_type == "webkit"
    assert Page.viewport_size(page) == %{width: 390, height: 664}
    assert Page.evaluate!(page, "[navigator.language, navigator.userAgent]") == ["de-DE", iphone.user_agent]
  end

  test "assert_expect raises a failed matcher as an ExUnit.AssertionError", %{page: page} do
    Page.goto!(page, "/sign-up")

    assert_raise ExUnit.AssertionError, ~r/toHaveText/, fn ->
      Assertions.assert_expect(fn -> Expect.to_have_text!(Page.get_by_role(page, :status), "Saved", timeout: 100) end)
    end
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.LoggedInTest do
  # "Logging in once", without the case template.
  use ExUnit.Case, async: true

  use PlaywrightEx.Test

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Guides.TestingWithExUnit.App
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.BrowserPool

  setup_all do
    server = App.start!(Path.join(System.tmp_dir!(), "guide-app-#{System.unique_integer([:positive])}"))
    browser = BrowserPool.browser()
    context = Browser.new_context!(browser, base_url: server.prefix)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/login")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_label(page, "Password") |> Locator.fill!("secret")
    Page.get_by_role(page, :button, name: "Log in") |> Locator.click!()
    Expect.to_have_url!(page, ~r"/dashboard$")

    storage_state = BrowserContext.storage_state!(context)
    BrowserContext.close!(context)
    %{browser: browser, storage_state: storage_state, base_url: server.prefix}
  end

  setup %{browser: browser, storage_state: storage_state, base_url: base_url} do
    context = Browser.new_context!(browser, storage_state: storage_state, base_url: base_url)
    %{context: context, page: BrowserContext.new_page!(context)}
  end

  test "assertions on a logged-in page", %{page: page} do
    Page.goto!(page, "/dashboard")
    Expect.to_have_url!(page, ~r"/dashboard$")
    Expect.to_be_visible!(Page.get_by_text(page, "Saved"))
    Page.get_by_role(page, :listitem) |> Expect.to_have_count!(3)
    Page.locator(page, ".error") |> Expect.not_() |> Expect.to_be_visible!()
    Page.get_by_text(page, "Saved") |> Expect.soft() |> Expect.to_be_visible!()
    Page.get_by_role(page, :listitem) |> Expect.soft() |> Expect.to_have_count!(3)
    assert Page.evaluate!(page, "localStorage.getItem('theme')") == "dark"
  end

  @tag :tmp_dir
  test "storage_state to a file", %{browser: browser, context: context, base_url: base_url, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "auth.json")
    BrowserContext.storage_state!(context, path: path)
    other = Browser.new_context!(browser, base_url: base_url, storage_state: path)
    page = BrowserContext.new_page!(other)
    Page.goto!(page, "/dashboard")
    Expect.to_have_url!(page, ~r"/dashboard$")
    BrowserContext.close!(other)
  end

  test "storage_state with IndexedDB", %{context: context, page: page} do
    Page.goto!(page, "/dashboard")

    Page.evaluate!(page, """
    () => new Promise(resolve => {
      const open = indexedDB.open('auth', 1);
      open.onupgradeneeded = () => open.result.createObjectStore('tokens');
      open.onsuccess = () => {
        const tx = open.result.transaction('tokens', 'readwrite');
        tx.objectStore('tokens').put('secret', 'id');
        tx.oncomplete = resolve;
      };
    })
    """)

    assert %{origins: [%{indexedDB: [%{name: "auth"}]}]} = BrowserContext.storage_state!(context, indexed_db: true)
    assert %{origins: origins} = BrowserContext.storage_state!(context)
    refute Enum.any?(origins, &Map.has_key?(&1, :indexedDB))
  end

  test "to_pass and poll", %{context: context} do
    Expect.to_pass!(fn ->
      response = APIRequestContext.get!(BrowserContext.request(context), "/api/exports/1")
      assert APIResponse.json!(response)["status"] == "done"
    end)

    # Deviation: an Agent for the guide's `Repo.aggregate(Export, :count)`.
    {:ok, exports} = Agent.start_link(fn -> 0 end)
    count = fn -> Agent.get_and_update(exports, &{&1, &1 + 1}) end
    Expect.poll!(fn -> count.() end, &assert(&1 == 1), timeout: 10_000)
  end

  test "forwarded events need an assert_receive timeout", %{page: page} do
    Page.goto!(page, "/dashboard")
    test_pid = self()
    Page.on(page, :console, &send(test_pid, {:console, ConsoleMessage.text(&1)}))
    Page.get_by_role(page, :button, name: "Save") |> Locator.click!()
    assert_receive {:console, "saved"}, 5_000
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.ArtifactsTest do
  # "Traces, screenshots and videos": the config's `TRACE` line, with `TRACE` set as by
  # `TRACE=1 mix test --failed`. Not async: it sets an environment variable and the config.
  use PlaywrightEx.Guides.TestingWithExUnit.BrowserCase, async: false

  alias PlaywrightEx.Test.TestInfo

  setup_all do
    config = Application.get_env(:playwright_ex, :test)
    System.put_env("TRACE", "1")
    trace = if(System.get_env("TRACE"), do: :on, else: :off)
    Application.put_env(:playwright_ex, :test, Keyword.put(config, :trace, trace))

    on_exit(fn ->
      System.delete_env("TRACE")
      Application.put_env(:playwright_ex, :test, config)
      dir = TestInfo.output_dir(%{module: __MODULE__, test: :"test signs up", file: __ENV__.file})
      # With its `-retryN` dirs under `mix test --failed`.
      dirs = [dir | Path.wildcard(dir <> "-retry*")]
      assert Enum.any?(dirs, &File.exists?(Path.join(&1, "trace.zip")))
      Enum.each(dirs, &File.rm_rf!/1)
    end)
  end

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.StepsTest do
  # "Steps".
  use PlaywrightEx.Guides.TestingWithExUnit.BrowserCase, async: true

  test "signs up in steps", %{page: page} do
    Test.step "fill in the form" do
      Page.goto!(page, "/sign-up")
      Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    end

    status =
      Test.step("submit", fn ->
        Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
        Page.get_by_role(page, :status)
      end)

    Expect.to_have_text!(status, "Welcome, ada@example.com")
  end

  test "a boxed helper", %{page: page} do
    sign_up(page, "ada@example.com")
    Expect.to_have_text!(Page.get_by_role(page, :status), "Welcome, ada@example.com")
  end

  defp sign_up(page, email) do
    Test.step "sign up", box: true do
      Page.goto!(page, "/sign-up")
      Page.get_by_label(page, "Email") |> Locator.fill!(email)
      Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
    end
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.SnapshotsTest do
  # "Snapshots", with `snapshot_dir` in a temporary dir. Not async: it sets the config.
  use PlaywrightEx.Guides.TestingWithExUnit.BrowserCase, async: false

  alias PlaywrightEx.Test.TestInfo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    config = Application.get_env(:playwright_ex, :test)
    Application.put_env(:playwright_ex, :test, Keyword.put(config, :snapshot_dir, tmp_dir))
    on_exit(fn -> Application.put_env(:playwright_ex, :test, config) end)
  end

  test "signs up", %{page: page, tmp_dir: tmp_dir} do
    Page.goto!(page, "/sign-up")
    Expect.to_have_screenshot!(page, name: "home.png")
    Expect.to_match_aria_snapshot!(Page.locator(page, "body"))

    platform = Atom.to_string(elem(:os.type(), 1))
    dir = Path.join(tmp_dir, "guides/testing_with_exunit_test.exs-snapshots")
    assert Test.snapshot_path("home.png", kind: :screenshot) == Path.join(dir, "home-#{platform}.png")
    assert File.exists?(Path.join(dir, "home-#{platform}.png"))
    assert File.exists?(Path.join(dir, "signs-up-1.aria.yml"))
    # Both written snapshots would fail the test at its end: taken here.
    assert [{:error, %RuntimeError{}, _}, {:error, %RuntimeError{}, _}] = TestInfo.take_errors(self())
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.ResultInOnExitTest do
  # "Traces, screenshots and videos": the result in an `on_exit` that runs after the recording.
  # Deviation: it asserts where the guide uploads a failure's trace.
  use ExUnit.Case, async: true

  @moduletag trace: :retain_on_failure

  setup %{test_pid: test_pid} do
    on_exit(fn ->
      %{status: status, output_dir: dir} = PlaywrightEx.Test.info(test_pid)
      assert status == :passed
      refute File.exists?(Path.join(dir, "trace.zip"))
    end)
  end

  use PlaywrightEx.Test

  test "passes" do
    page =
      PlaywrightEx.BrowserContext.new_page!(PlaywrightEx.Browser.new_context!(PlaywrightEx.Test.BrowserPool.browser()))

    PlaywrightEx.Page.set_content!(page, "<h1>Hi</h1>")
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.WorkersTest do
  # "Workers".
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.BrowserPool

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  test "a browser of the module's, also for the test's own call", %{browser: browser} do
    assert Browser.is_connected(browser)
    assert BrowserPool.browser() == browser
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.DebugTest do
  # "Debugging one test". Deviation: `BROWSER`'s.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.BrowserPool

  @moduletag :debug
  @moduletag :headed

  setup_all do
    %{browser: BrowserPool.browser(launch_options: [headless: false, slow_mo: 500])}
  end

  setup %{browser: browser} do
    context = Browser.new_context!(browser)
    %{context: context, page: BrowserContext.new_page!(context)}
  end

  test "a headed, slowed-down browser of the module's own", %{page: page} do
    Page.set_content!(page, "<p>Debug</p>")
    assert Page.text_content!(page, "p") == "Debug"
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.RemoteTest do
  # "Remote browsers": the config's `connect_options` (its env var line) as the call's, on a
  # `run-server`.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Guides.TestingWithExUnit.App
  alias PlaywrightEx.Page
  alias PlaywrightEx.RemoteServer.RunServer
  alias PlaywrightEx.Test.BrowserPool

  setup_all do
    server = RunServer.start()
    on_exit(fn -> RunServer.close(server) end)
    app = App.start!(Path.join(System.tmp_dir!(), "guide-app-#{System.unique_integer([:positive])}"))
    System.put_env("PW_TEST_CONNECT_WS_ENDPOINT", RunServer.ws_endpoint(server))
    connect_options = if(url = System.get_env("PW_TEST_CONNECT_WS_ENDPOINT"), do: [ws_endpoint: url])
    System.delete_env("PW_TEST_CONNECT_WS_ENDPOINT")
    browser = BrowserPool.browser(connect_options: connect_options ++ [expose_network: "<loopback>"])
    %{browser: browser, base_url: app.prefix}
  end

  test "a page of the remote browser reaches the app on localhost", %{browser: browser, base_url: base_url} do
    page = BrowserContext.new_page!(Browser.new_context!(browser, base_url: base_url))
    Page.goto!(page, "/sign-up")
    Expect.to_have_text!(Page.get_by_role(page, :button), "Sign up")
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.PageChecksTest do
  # "A check after the test" and the listener lifetimes of "Route handlers and listeners".
  use PlaywrightEx.Case, async: true

  setup %{page: page} = ctx do
    {:ok, errors} = Agent.start(fn -> [] end)
    Page.on(page, :page_error, fn error -> Agent.update(errors, &(&1 ++ [error])) end)

    on_exit(fn ->
      page_errors = Agent.get(errors, & &1)
      Agent.stop(errors)
      if !ctx[:ignore_js_errors], do: assert(page_errors == [], "unhandled page errors")
    end)
  end

  test "no page errors: the check passes", %{page: page} do
    Page.set_content!(page, "<p>Fine</p>")
  end

  @tag ignore_js_errors: true
  test "a page error, ignored by the tag", %{page: page} do
    Page.set_content!(page, "<button onclick='throw new Error(`boom`)'>Go</button>")
    Page.get_by_role(page, :button) |> Locator.click!()
  end

  test "a listener sends to the test process: a late event is dropped with it", %{page: page} do
    test_pid = self()
    Page.on(page, :console, &send(test_pid, {:console, PlaywrightEx.ConsoleMessage.text(&1)}))
    Page.evaluate!(page, "console.log('now')")
    assert_receive {:console, "now"}
    # Fires after the test process exited, as the context closes in the test's last `on_exit`.
    Page.evaluate!(page, "setTimeout(() => console.log('late'), 0)")
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.ProjectsCase do
  @moduledoc false
  # "Projects". Deviation: `BROWSER`'s browser only.
  use ExUnit.CaseTemplate
  use PlaywrightEx.Test

  alias PlaywrightEx.{Browser, BrowserContext, Playwright}
  alias PlaywrightEx.Test.BrowserPool

  @devices %{chromium: "Desktop Chrome", firefox: "Desktop Firefox", webkit: "Desktop Safari"}

  def projects, do: for(name <- [String.to_atom(PlaywrightEx.TestBrowser.name())], do: %{browser_name: name})

  using do
    quote do
      use PlaywrightEx.Test
      alias PlaywrightEx.{Browser, BrowserContext, Expect, Locator, Page}
    end
  end

  setup_all %{browser_name: name} do
    %{browser: BrowserPool.browser(browser_name: name)}
  end

  setup %{browser: browser, browser_name: name} do
    device = Map.fetch!(Playwright.devices(BrowserPool.playwright(browser)), @devices[name])
    context = Browser.new_context!(browser, device)
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.ProjectsTest do
  use PlaywrightEx.Guides.TestingWithExUnit.ProjectsCase,
    async: true,
    parameterize: PlaywrightEx.Guides.TestingWithExUnit.ProjectsCase.projects()

  @user_agents %{chromium: "Chrome", firefox: "Firefox", webkit: "Safari"}

  test "a page of the project's browser, with its device", %{page: page, browser_name: name} do
    assert Page.evaluate!(page, "navigator.userAgent") =~ @user_agents[name]
    assert Page.viewport_size(page) == %{width: 1280, height: 720}
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.PortingTest do
  # "Porting Playwright Test specs".
  use PlaywrightEx.Case, async: true

  alias PlaywrightEx.JSHandle

  test "null, objects, regexes and element handles", %{page: page} do
    assert Page.evaluate!(page, "() => ({ entry: { foo: null }, gone: undefined })") ==
             %{"entry" => %{"foo" => :null}, "gone" => nil}

    Page.set_content!(page, "<p>patched=true</p>")
    Expect.to_have_text!(Page.locator(page, "p"), PlaywrightEx.RegExp.new("\\patched=true"))

    element_handle = Page.query_selector!(page, "p")
    assert JSHandle.evaluate!(element_handle, "e => e.textContent") == "patched=true"
  end
end
