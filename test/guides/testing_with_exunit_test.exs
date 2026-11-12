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
    %{base_url: server.prefix}
  end

  # `@tag locale: "de-DE"` on a test.
  setup ctx do
    options = [base_url: ctx.base_url] ++ Enum.to_list(Map.take(ctx, [:locale]))
    context = Browser.new_context!(BrowserPool.shared(), options)
    BrowserContext.set_default_timeout(context, 5_000)
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.Eventually do
  @moduledoc false
  @doc "Calls `fun` until it doesn't raise, for up to `timeout` ms, then raises its last error."
  def eventually(fun, timeout \\ 5_000, interval \\ 100) do
    retry(fun, System.monotonic_time(:millisecond) + timeout, interval)
  end

  defp retry(fun, deadline, interval) do
    fun.()
  rescue
    error ->
      if System.monotonic_time(:millisecond) >= deadline, do: reraise(error, __STACKTRACE__)
      Process.sleep(interval)
      retry(fun, deadline, interval)
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
  alias PlaywrightEx.Guides.TestingWithExUnit.Eventually

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
  test "two users edit one document" do
    browser = BrowserPool.shared()
    ada = Browser.new_context!(browser)
    bob = Browser.new_context!(browser)
    other = BrowserPool.shared(launch_options: [slow_mo: 1])
    eve = Browser.new_context!(other)

    ada_page = BrowserContext.new_page!(ada)
    bob_page = BrowserContext.new_page!(bob)
    eve_page = BrowserContext.new_page!(eve)
    assert BrowserContext.browser(eve) == other
    for page <- [ada_page, bob_page, eve_page], do: Page.set_content!(page, "<p>Doc</p>")
  end

  test "assert_expect raises a failed matcher as an ExUnit.AssertionError", %{page: page} do
    Page.goto!(page, "/sign-up")

    assert_raise ExUnit.AssertionError, ~r/toHaveText/, fn ->
      Assertions.assert_expect(fn -> Expect.to_have_text!(Page.get_by_role(page, :status), "Saved", timeout: 100) end)
    end
  end

  test "eventually raises the last error after the timeout" do
    assert_raise ExUnit.AssertionError, fn -> Eventually.eventually(fn -> assert 1 == 2 end, 200) end
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.LoggedInTest do
  # "Logging in once", without the case template.
  use ExUnit.Case, async: true

  import PlaywrightEx.Guides.TestingWithExUnit.Eventually
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
    context = Browser.new_context!(BrowserPool.shared(), base_url: server.prefix)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/login")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_label(page, "Password") |> Locator.fill!("secret")
    Page.get_by_role(page, :button, name: "Log in") |> Locator.click!()
    Expect.to_have_url!(page, ~r"/dashboard$")

    storage_state = BrowserContext.storage_state!(context)
    BrowserContext.close!(context)
    %{storage_state: storage_state, base_url: server.prefix}
  end

  setup %{storage_state: storage_state, base_url: base_url} do
    context = Browser.new_context!(BrowserPool.shared(), storage_state: storage_state, base_url: base_url)
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
  test "storage_state to a file", %{context: context, base_url: base_url, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "auth.json")
    BrowserContext.storage_state!(context, path: path)
    other = Browser.new_context!(BrowserPool.shared(), base_url: base_url, storage_state: path)
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

  test "eventually", %{context: context} do
    eventually(fn ->
      response = APIRequestContext.get!(BrowserContext.request(context), "/api/exports/1")
      assert APIResponse.json!(response)["status"] == "done"
    end)
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

  alias PlaywrightEx.Test.Recorder

  setup_all do
    config = Application.get_env(:playwright_ex, :test)
    System.put_env("TRACE", "1")
    trace = if(System.get_env("TRACE"), do: :on, else: :off)
    Application.put_env(:playwright_ex, :test, Keyword.put(config, :trace, trace))

    on_exit(fn ->
      System.delete_env("TRACE")
      Application.put_env(:playwright_ex, :test, config)
      dir = Recorder.output_dir(%{module: __MODULE__, test: :"test signs up", file: __ENV__.file})
      assert File.exists?(Path.join(dir, "trace.zip"))
      File.rm_rf!(dir)
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

defmodule PlaywrightEx.Guides.TestingWithExUnit.ExclusiveTest do
  # "Exclusive browsers".
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.BrowserPool

  setup_all do
    %{browser: BrowserPool.exclusive()}
  end

  test "a browser of the module's own", %{browser: browser} do
    assert Browser.is_connected(browser)
    refute browser == BrowserPool.shared()
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.RemoteTest do
  # "Remote browsers": the config's `connect_options` as the call's, on a `run-server`.
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
    connect_options = [ws_endpoint: RunServer.ws_endpoint(server), expose_network: "<loopback>"]
    %{browser: BrowserPool.shared(connect_options: connect_options), base_url: app.prefix}
  end

  test "a page of the remote browser reaches the app on localhost", %{browser: browser, base_url: base_url} do
    page = BrowserContext.new_page!(Browser.new_context!(browser, base_url: base_url))
    Page.goto!(page, "/sign-up")
    Expect.to_have_text!(Page.get_by_role(page, :button), "Sign up")
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.GroupTest do
  # "Exclusive browsers": a group's modules share a browser. Deviation: `BROWSER`'s.
  use ExUnit.Case, async: true, group: :firefox
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.BrowserPool

  setup do
    context = Browser.new_context!(BrowserPool.shared(browser_name: String.to_atom(PlaywrightEx.TestBrowser.name())))
    %{page: BrowserContext.new_page!(context)}
  end

  test "a page of the shared browser", %{page: page} do
    Page.set_content!(page, "<p>Group</p>")
    assert PlaywrightEx.Test.info().test_pid == self()
  end
end
