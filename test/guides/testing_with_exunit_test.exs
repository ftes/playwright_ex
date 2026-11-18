# The snippets of `guides/testing-with-exunit.md`, run against an app on `Playwright.TestServer`.
# Deviations from the guide: each module starts its own app, and the browser is `BROWSER`'s.

defmodule Playwright.Guides.TestingWithExUnit.App do
  @moduledoc false
  alias Playwright.TestServer

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

defmodule Playwright.Guides.TestingWithExUnit.BrowserCase do
  @moduledoc false
  # The guide's case template from the pieces. Deviation: `base_url` is the module's own app,
  # not the config's.
  use ExUnit.CaseTemplate
  use Playwright.Test

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Guides.TestingWithExUnit.App
  alias Playwright.Test.BrowserPool

  # Its options forwarded, its own popped first, as "Traces, screenshots and videos" shows.
  using opts do
    {sandbox, opts} = Keyword.pop(opts, :sandbox, true)

    quote do
      use Playwright.Test, unquote(opts)
      @moduletag sandbox: unquote(sandbox)
      alias Playwright.{Browser, BrowserContext, Expect, Locator, Page, Test}
      alias Playwright.Test.BrowserPool
    end
  end

  setup_all do
    server = App.start!(Path.join(System.tmp_dir!(), "guide-app-#{System.unique_integer([:positive])}"))
    %{base_url: server.prefix, browser: BrowserPool.browser()}
  end

  # `@tag Test.use(locale: "de-DE")` on a test sets its options.
  setup %{browser: browser} = ctx do
    context = Browser.new_context!(browser, base_url: ctx.base_url)
    BrowserContext.set_default_timeout(context, 5_000)
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end

defmodule Playwright.Guides.TestingWithExUnit.Assertions do
  @moduledoc false
  @doc "Runs `fun`, re-raising a failed matcher as an `ExUnit.AssertionError`."
  def assert_expect(fun) do
    fun.()
  rescue
    e in Playwright.ExpectError ->
      reraise ExUnit.AssertionError, [message: Exception.message(e)], __STACKTRACE__
  end
end

defmodule Playwright.Guides.TestingWithExUnit.SignUpTest do
  use Playwright.Guides.TestingWithExUnit.BrowserCase, async: true

  alias Playwright.Guides.TestingWithExUnit.Assertions

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
    Expect.to_have_text!(Page.get_by_role(page, :status), "Welcome, ada@example.com")
  end

  @tag Test.use(locale: "de-DE")
  test "a test's options through the case template", %{page: page} do
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
    browser = BrowserPool.browser()
    iphone = Playwright.device("iPhone 13")
    page = BrowserContext.new_page!(Browser.new_context!(browser, iphone ++ [locale: "de-DE"]))
    assert iphone[:default_browser_type] == "webkit"
    assert Playwright.devices()["iPhone 13"] == iphone
    assert_raise ArgumentError, ~r/"iPhone 13"/, fn -> Playwright.device("iPhone13") end
    assert Page.viewport_size(page) == %{width: 390, height: 664}
    assert Page.evaluate!(page, "[navigator.language, navigator.userAgent]") == ["de-DE", iphone[:user_agent]]
  end

  test "assert_expect raises a failed matcher as an ExUnit.AssertionError", %{page: page} do
    Page.goto!(page, "/sign-up")

    assert_raise ExUnit.AssertionError, ~r/toHaveText/, fn ->
      Assertions.assert_expect(fn -> Expect.to_have_text!(Page.get_by_role(page, :status), "Saved", timeout: 100) end)
    end
  end
end

defmodule Playwright.Guides.TestingWithExUnit.LoggedInTest do
  # "Logging in once", without the case template.
  use ExUnit.Case, async: true

  use Playwright.Test

  alias Playwright.APIRequestContext
  alias Playwright.APIResponse
  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.ConsoleMessage
  alias Playwright.Expect
  alias Playwright.Guides.TestingWithExUnit.App
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.Test.BrowserPool

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

defmodule Playwright.Guides.TestingWithExUnit.ArtifactsTest do
  # "Traces, screenshots and videos": the config's `trace: :on_first_retry`, which traces the
  # test under `mix test --failed` only. Not async: it sets the config.
  use Playwright.Guides.TestingWithExUnit.BrowserCase, async: false

  alias Playwright.Test.TestInfo

  setup_all do
    config = Application.get_env(:playwright, :test)
    Application.put_env(:playwright, :test, Keyword.put(config, :trace, :on_first_retry))

    on_exit(fn ->
      Application.put_env(:playwright, :test, config)
      dir = TestInfo.output_dir(%{module: __MODULE__, test: :"test signs up", file: __ENV__.file})
      traced = Path.wildcard(dir <> "*/trace.zip")
      if ExUnit.configuration()[:only_test_ids], do: assert([_ | _] = traced), else: assert(traced == [])
      Enum.each([dir | Path.wildcard(dir <> "-retry*")], &File.rm_rf!/1)
    end)
  end

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
  end
end

defmodule Playwright.Guides.TestingWithExUnit.UseOptionsTest do
  # "Traces, screenshots and videos": the modes of the template's options, under the tags.
  # Deviation: `retain_on_failure`, so the passing test leaves no files.
  use Playwright.Guides.TestingWithExUnit.BrowserCase,
    async: true,
    trace: :retain_on_failure,
    video: :on,
    sandbox: false

  @tag Playwright.Test.use(video: :retain_on_failure)
  test "checks out", %{page: page} = ctx do
    refute ctx.sandbox
    Page.goto!(page, "/sign-up")
    registration = Playwright.Test.Recorder.registration(self())
    assert [mode: :retain_on_failure] ++ _ = registration.trace
    assert registration.video == [mode: :retain_on_failure]
  end
end

defmodule Playwright.Guides.TestingWithExUnit.StepsTest do
  # "Steps".
  use Playwright.Guides.TestingWithExUnit.BrowserCase, async: true

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

defmodule Playwright.Guides.TestingWithExUnit.SnapshotsTest do
  # "Snapshots", with `snapshot_dir` in a temporary dir. Not async: it sets the config.
  use Playwright.Guides.TestingWithExUnit.BrowserCase, async: false

  alias Playwright.Test.TestInfo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    config = Application.get_env(:playwright, :test)
    Application.put_env(:playwright, :test, Keyword.put(config, :snapshot_dir, tmp_dir))
    on_exit(fn -> Application.put_env(:playwright, :test, config) end)
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

defmodule Playwright.Guides.TestingWithExUnit.ResultInOnExitTest do
  # "Traces, screenshots and videos": the result in an `on_exit` that runs after the recording.
  # Deviation: it asserts where the guide uploads a failure's trace.
  use ExUnit.Case, async: true

  @moduletag Playwright.Test.use(trace: :retain_on_failure)

  setup %{test_pid: test_pid} do
    on_exit(fn ->
      %{status: status, output_dir: dir} = Playwright.Test.info(test_pid)
      assert status == :passed
      refute File.exists?(Path.join(dir, "trace.zip"))
    end)
  end

  use Playwright.Test

  test "passes" do
    page =
      Playwright.BrowserContext.new_page!(Playwright.Browser.new_context!(Playwright.Test.BrowserPool.browser()))

    Playwright.Page.set_content!(page, "<h1>Hi</h1>")
  end
end

defmodule Playwright.Guides.TestingWithExUnit.WorkersTest do
  # "Workers".
  use ExUnit.Case, async: true
  use Playwright.Test

  alias Playwright.Browser
  alias Playwright.Test.BrowserPool

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  test "a browser of the module's, also for the test's own call", %{browser: browser} do
    assert Browser.is_connected(browser)
    assert BrowserPool.browser() == browser
  end
end

defmodule Playwright.Guides.TestingWithExUnit.DebugTest do
  # "Debugging one test". Deviation: `BROWSER`'s.
  use ExUnit.Case, async: true
  use Playwright.Test

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Page
  alias Playwright.Test.BrowserPool

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

defmodule Playwright.Guides.TestingWithExUnit.RemoteTest do
  # "Remote browsers": the config's `connect_options` (its env var line) as the call's, on a
  # `run-server`.
  use ExUnit.Case, async: true
  use Playwright.Test

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Expect
  alias Playwright.Guides.TestingWithExUnit.App
  alias Playwright.Page
  alias Playwright.RemoteServer.RunServer
  alias Playwright.Test.BrowserPool

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

defmodule Playwright.Guides.TestingWithExUnit.PageChecksTest do
  # "A check after the test" and the listener lifetimes of "Route handlers and listeners".
  use Playwright.Case, async: true

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
    Page.on(page, :console, &send(test_pid, {:console, Playwright.ConsoleMessage.text(&1)}))
    Page.evaluate!(page, "console.log('now')")
    assert_receive {:console, "now"}
    # Fires after the test process exited, as the context closes in the test's last `on_exit`.
    Page.evaluate!(page, "setTimeout(() => console.log('late'), 0)")
  end
end

defmodule Playwright.Guides.TestingWithExUnit.Projects do
  @moduledoc false
  # "Projects". Deviation: one project by default, as the suite's config sets `browser_name`
  # (`BROWSER`), which wins over a device's browser.
  def all do
    names = String.split(System.get_env("PROJECTS", "Desktop Chrome"), ",")
    for name <- names, do: Playwright.Test.parameters(Playwright.device(name))
  end
end

defmodule Playwright.Guides.TestingWithExUnit.ProjectsTest do
  use Playwright.Case, async: true, parameterize: Playwright.Guides.TestingWithExUnit.Projects.all()

  @chrome Playwright.device("Desktop Chrome")

  setup_all %{browser: browser} do
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close!(context) end)
    %{setup_all_page: BrowserContext.new_page!(context)}
  end

  test "every context of the run has the project's device", %{page: page, browser: browser} = ctx do
    assert Playwright.BrowserType.name(Browser.browser_type(browser)) == Playwright.TestBrowser.name()

    for page <- [page, ctx.setup_all_page, BrowserContext.new_page!(Browser.new_context!(browser))] do
      assert Page.evaluate!(page, "navigator.userAgent") == @chrome[:user_agent]
      assert Page.viewport_size(page) == %{width: 1280, height: 720}
    end
  end
end

defmodule Playwright.Guides.TestingWithExUnit.ProjectsOptionsTest do
  # "Projects": the module's `use` options over the project's device, parameters of your own.
  use Playwright.Case,
    async: true,
    parameterize:
      for(project <- Playwright.Guides.TestingWithExUnit.Projects.all(), do: Map.put(project, :role, :admin)),
    locale: "de-DE"

  test "the module's options over the device", %{page: page, role: :admin} do
    assert Page.evaluate!(page, "navigator.language") == "de-DE"
    assert Page.evaluate!(page, "navigator.userAgent") == Playwright.device("Desktop Chrome")[:user_agent]
  end
end

defmodule Playwright.Guides.TestingWithExUnit.DeviceLevelsTest do
  # "Devices": a describe block's options, a test's, and generated tests.
  use Playwright.Case, async: true

  defp timezone(page), do: Page.evaluate!(page, "Intl.DateTimeFormat().resolvedOptions().timeZone")

  describe "in Berlin" do
    @describetag Test.use(timezone_id: "Europe/Berlin", locale: "de-DE")

    test "shows local time", %{page: page} do
      assert timezone(page) == "Europe/Berlin"
      assert Page.evaluate!(page, "navigator.language") == "de-DE"
    end
  end

  @tag Test.use(color_scheme: :dark, trace: :retain_on_failure)
  test "is readable in the dark", %{page: page} do
    assert Page.evaluate!(page, "matchMedia('(prefers-color-scheme: dark)').matches")
    assert [mode: :retain_on_failure] ++ _ = Playwright.Test.Recorder.registration(self()).trace
  end

  for name <- ["iPhone 13", "Pixel 7"] do
    @tag Test.use(Playwright.device(name))
    test "the menu collapses on #{name}", %{page: page, browser: browser} do
      device = Playwright.device(unquote(name))
      assert Page.evaluate!(page, "navigator.userAgent") == device[:user_agent]
      assert Page.viewport_size(page) == device[:viewport]
      # A tag's device doesn't switch the browser: its `default_browser_type` is ignored.
      assert Playwright.BrowserType.name(Browser.browser_type(browser)) == Playwright.TestBrowser.name()
    end
  end
end

defmodule Playwright.Guides.TestingWithExUnit.PortingTest do
  # "Porting Playwright Test specs".
  use Playwright.Case, async: true

  alias Playwright.JSHandle

  test "null, objects, regexes and element handles", %{page: page} do
    assert Page.evaluate!(page, "() => ({ entry: { foo: null }, gone: undefined })") ==
             %{"entry" => %{"foo" => :null}, "gone" => nil}

    Page.set_content!(page, "<p>patched=true</p>")
    Expect.to_have_text!(Page.locator(page, "p"), Playwright.RegExp.new("\\patched=true"))

    element_handle = Page.query_selector!(page, "p")
    assert JSHandle.evaluate!(element_handle, "e => e.textContent") == "patched=true"
    assert Locator.get_attribute!(Page.locator(page, "p"), "title") == nil
  end

  test "init scripts and selectors with parentheses", %{context: context, page: page} do
    # Only defined, not called.
    BrowserContext.add_init_script!(context, "() => window.defined = true")
    fun = "() => window.called = true"
    BrowserContext.add_init_script!(context, "(#{fun})()")
    Page.route!(page, "**/*", &Playwright.Route.fulfill!(&1, body: "<div>(a)</div>", content_type: "text/html"))
    Page.goto!(page, "http://app.test/")
    assert Page.evaluate!(page, "[window.defined, window.called]") == [nil, true]
    Expect.to_be_visible!(Page.locator(page, ~s[div:has-text("(a)")]))
  end

  test "poll a list that starts empty", %{page: page} do
    Page.set_content!(page, "<ul></ul>")
    Page.evaluate!(page, "setTimeout(() => document.querySelector('ul').innerHTML = '<li>One</li>', 300)")
    rows = fn -> Page.locator(page, "li") |> Locator.all_text_contents!() end
    Expect.poll!(fn -> Enum.at(rows.(), 0) end, &assert(&1 == "One"))
  end

  test "drain the forwarded events", %{page: page} do
    test_pid = self()
    Page.on(page, :console, &send(test_pid, {:console, Playwright.ConsoleMessage.text(&1)}))
    Page.evaluate!(page, "console.log('saved')")
    assert received(:console) == ["saved"]
  end

  defp received(tag) do
    receive do
      {^tag, value} -> [value | received(tag)]
    after
      0 -> []
    end
  end

  # "Coming from Wallaby".
  test "Wallaby's assertions", %{page: page} do
    Page.set_content!(page, """
    <p class="alert">Saved</p><ul><li>Apple</li><li>Pear</li></ul>
    <p id="color" style="text-transform: uppercase">red</p>
    """)

    Page.locator(page, ".alert") |> Locator.filter(has_text: "Saved") |> Expect.to_be_visible!()
    Page.locator(page, ".error") |> Expect.not_to_be_visible!()
    Page.get_by_role(page, :listitem) |> Locator.filter(has_text: "Apple") |> Expect.to_be_visible!()
    Expect.to_have_text!(Page.locator(page, "#color"), "RED", use_inner_text: true)
  end
end

defmodule Playwright.Guides.TestingWithExUnit.OncePerRunTest do
  # "Logging in once": the once-per-run login of `test_helper.exs`, run in `setup_all`, and the
  # config's `context_options` from it; the `baseURL` and `request` fixtures of "Porting
  # Playwright Test specs". Not async: it sets the config.
  use ExUnit.Case, async: false
  use Playwright.Test

  alias Playwright.APIRequest
  alias Playwright.APIRequestContext
  alias Playwright.APIResponse
  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.BrowserType
  alias Playwright.Expect
  alias Playwright.Guides.TestingWithExUnit.App
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.Test.BrowserPool

  setup_all do
    dir = Path.join(System.tmp_dir!(), "guide-app-#{System.unique_integer([:positive])}")
    server = App.start!(dir)
    config = Application.get_env(:playwright, :test)
    on_exit(fn -> Application.put_env(:playwright, :test, config) end)
    Application.put_env(:playwright, :test, Keyword.put(config, :base_url, server.prefix))
    auth = Path.join(dir, "auth.json")

    # Deviation: the browser under test, and the guide's `tmp/auth.json` in a temporary dir.
    {:ok, driver} = Playwright.Supervisor.start_link(name: MyApp.GlobalSetup)
    browser = Playwright.instance(MyApp.GlobalSetup) |> Playwright.TestBrowser.browser_type() |> BrowserType.launch!()
    context = Browser.new_context!(browser, base_url: Playwright.Test.config()[:base_url])
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/login")
    Page.get_by_role(page, :button, name: "Log in") |> Locator.click!()
    Expect.to_have_url!(page, ~r"/dashboard$")
    BrowserContext.storage_state!(context, path: auth)
    Supervisor.stop(driver)

    Application.put_env(:playwright, :test, Keyword.merge(config, base_url: server.prefix, storage_state: auth))

    %{browser: BrowserPool.browser(), base_url: server.prefix}
  end

  test "every context starts logged in", %{browser: browser} do
    page = BrowserContext.new_page!(Browser.new_context!(browser))
    Page.goto!(page, "/dashboard")
    Expect.to_have_url!(page, ~r"/dashboard$")
  end

  test "the baseURL and request fixtures", %{browser: browser, base_url: base_url} do
    assert Playwright.Test.config()[:base_url] == base_url
    request = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))
    assert %{"status" => _} = APIResponse.json!(APIRequestContext.get!(request, "/api/exports/1"))
  end
end

defmodule Playwright.Guides.TestingWithExUnit.OnExitTest do
  # "Your own case template": an `on_exit` uses the page and closes the context, which is still
  # traced; the check runs after the recording, registered before it.
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Page
  alias Playwright.Test.BrowserPool

  @moduletag Playwright.Test.use(trace: :on)

  setup %{test_pid: test_pid} do
    on_exit(fn ->
      %{output_dir: dir} = Playwright.Test.info(test_pid)
      {:ok, files} = :zip.unzip(String.to_charlist(Path.join(dir, "trace.zip")), [:memory])
      File.rm_rf!(dir)
      # The context's own trace, not the test's steps (`test.trace`), has the `on_exit`'s call.
      context_traces =
        for {name, data} <- files, Path.extname(to_string(name)) == ".trace", to_string(name) != "test.trace", do: data

      assert Enum.any?(context_traces, &(&1 =~ "from on_exit"))
    end)
  end

  use Playwright.Test

  setup do
    context = Browser.new_context!(BrowserPool.browser())
    page = BrowserContext.new_page!(context)

    on_exit(fn ->
      Page.set_content!(page, "<p>after</p>")
      assert Page.evaluate!(page, "document.querySelector('p').textContent + ' from on_exit'") == "after from on_exit"
      BrowserContext.close!(context)
    end)

    %{page: page}
  end

  test "passes", %{page: page} do
    Page.set_content!(page, "<p>Hi</p>")
  end
end

defmodule Playwright.Guides.TestingWithExUnit.GroupTest do
  # "Setup": modules sharing state in the app, async in one group.
  use Playwright.Case, async: true, group: :guide_group

  test "the module's group" do
    assert %{async?: true, group: :guide_group} = __MODULE__.__ex_unit__(:config)
  end
end

defmodule Playwright.Guides.TestingWithExUnit.PhoneTest do
  # "Devices": the module's context options of a device. Deviation: the browser is `BROWSER`'s.
  use Playwright.Case, async: true
  use Playwright.Test, Playwright.device("iPhone 13")

  @iphone Playwright.device("iPhone 13")

  test "on a phone", %{page: page, browser: browser} do
    assert Page.viewport_size(page) == %{width: 390, height: 664}
    assert Page.evaluate!(page, "navigator.userAgent") == @iphone[:user_agent]

    page = BrowserContext.new_page!(Browser.new_context!(browser, viewport: %{width: 800, height: 600}))
    assert Page.viewport_size(page) == %{width: 800, height: 600}
    assert Page.evaluate!(page, "navigator.userAgent") == @iphone[:user_agent]
  end

  describe "in German" do
    @describetag Test.use(locale: "de-DE")

    test "the module's device with the describe's locale: the levels merge per option", %{page: page} do
      assert Page.viewport_size(page) == %{width: 390, height: 664}
      assert Page.evaluate!(page, "[navigator.language, navigator.userAgent]") == ["de-DE", @iphone[:user_agent]]
    end
  end
end

defmodule Playwright.Guides.TestingWithExUnit.SharedPageTest do
  # "Porting Playwright Test specs": one page of `setup_all`, without `Playwright.Case`.
  use ExUnit.Case, async: true
  use Playwright.Test

  alias Playwright.{Browser, BrowserContext, Page}
  alias Playwright.Test.BrowserPool

  setup_all do
    context = Browser.new_context!(BrowserPool.browser())
    on_exit(fn -> BrowserContext.close!(context) end)
    %{page: BrowserContext.new_page!(context)}
  end

  test "shows the list", %{page: page} do
    # The defaults.
    assert Page.viewport_size(page) == %{width: 1280, height: 720}
    assert Page.evaluate!(page, "navigator.language") == "en-US"
  end
end
