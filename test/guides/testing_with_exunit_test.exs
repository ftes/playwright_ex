# The snippets of `guides/testing-with-exunit.md`, run against an app on `PlaywrightEx.TestServer`.
# Deviations from the guide: each module starts its own driver, browser and app (the guide starts
# one driver and browser for the run in `test_helper.exs` and reads `BASE_URL`; this suite's
# test_helper is shared), and the browser is `BROWSER`'s.

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
  use ExUnit.CaseTemplate

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Guides.TestingWithExUnit.App
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.Tracing

  setup_all %{module: module} do
    start_supervised!({PlaywrightEx.Supervisor, name: module})
    server = App.start!(Path.join(System.tmp_dir!(), "guide-app-#{System.unique_integer([:positive])}"))

    browser = PlaywrightEx.playwright(module) |> TestBrowser.browser_type() |> BrowserType.launch!()
    on_exit(fn -> Browser.close(browser) end)
    %{browser: browser, base_url: server.prefix}
  end

  setup %{browser: browser} = ctx do
    context =
      Browser.new_context!(browser,
        base_url: ctx.base_url,
        storage_state: ctx[:storage_state]
      )

    BrowserContext.set_default_timeout(context, 5_000)
    on_exit(fn -> BrowserContext.close(context) end)
    page = BrowserContext.new_page!(context)
    tracing = BrowserContext.tracing(context)
    Tracing.start!(tracing, screenshots: true, snapshots: true, sources: true)
    dir = artifacts_dir(ctx.module, ctx.test)

    on_exit(fn ->
      Page.screenshot(page, path: Path.join(dir, "failure.png"))
      Tracing.stop(tracing, path: Path.join(dir, "trace.zip"))
    end)

    %{context: context, page: page}
  end

  def artifacts_dir(module, test) do
    Path.join(["tmp/test-results", inspect(module), String.replace(to_string(test), ~r/\W+/, "_")])
  end
end

defmodule PlaywrightEx.Guides.TestingWithExUnit.RetainOnFailure do
  @moduledoc "An ExUnit formatter that deletes the artifacts of passing tests (retain-on-failure)."
  use GenServer

  alias PlaywrightEx.Guides.TestingWithExUnit.BrowserCase

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: nil} = test}, state) do
    File.rm_rf!(BrowserCase.artifacts_dir(test.module, test.name))
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
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

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Guides.TestingWithExUnit.Assertions
  alias PlaywrightEx.Guides.TestingWithExUnit.BrowserCase
  alias PlaywrightEx.Guides.TestingWithExUnit.Eventually
  alias PlaywrightEx.Guides.TestingWithExUnit.RetainOnFailure
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  # Retain on failure: the setup's `on_exit` wrote each test's artifacts; the formatter deletes
  # those of passing ones.
  setup_all do
    on_exit(fn ->
      dir = BrowserCase.artifacts_dir(__MODULE__, :"test signs up")
      assert File.exists?(Path.join(dir, "trace.zip"))
      assert File.exists?(Path.join(dir, "failure.png"))

      failed = %ExUnit.Test{module: __MODULE__, name: :"test signs up", state: {:failed, []}}
      {:noreply, _} = RetainOnFailure.handle_cast({:test_finished, failed}, [])
      assert File.exists?(dir)

      {:noreply, _} = RetainOnFailure.handle_cast({:test_finished, %{failed | state: nil}}, [])
      refute File.exists?(dir)
      File.rm_rf!(Path.join("tmp/test-results", inspect(__MODULE__)))
    end)
  end

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
    Expect.to_have_text!(Page.get_by_role(page, :status), "Welcome, ada@example.com")
  end

  test "artifacts_dir" do
    assert BrowserCase.artifacts_dir(MyApp.SignUpTest, :"test signs up") ==
             "tmp/test-results/MyApp.SignUpTest/test_signs_up"
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
  use PlaywrightEx.Guides.TestingWithExUnit.BrowserCase, async: true

  import PlaywrightEx.Guides.TestingWithExUnit.Eventually

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  setup_all %{browser: browser, base_url: base_url} do
    context = Browser.new_context!(browser, base_url: base_url)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/login")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_label(page, "Password") |> Locator.fill!("secret")
    Page.get_by_role(page, :button, name: "Log in") |> Locator.click!()
    Expect.to_have_url!(page, ~r"/dashboard$")

    storage_state = BrowserContext.storage_state!(context)
    BrowserContext.close!(context)
    on_exit(fn -> File.rm_rf!(Path.join("tmp/test-results", inspect(__MODULE__))) end)
    %{storage_state: storage_state}
  end

  test "assertions on a logged-in page", %{page: page} do
    Page.goto!(page, "/dashboard")
    Expect.to_have_url!(page, ~r"/dashboard$")
    Expect.to_be_visible!(Page.get_by_text(page, "Saved"))
    Page.get_by_role(page, :listitem) |> Expect.to_have_count!(3)
    Page.locator(page, ".error") |> Expect.not_() |> Expect.to_be_visible!()
    assert Page.evaluate!(page, "localStorage.getItem('theme')") == "dark"
  end

  @tag :tmp_dir
  test "storage_state to a file", %{context: context, browser: browser, base_url: base_url, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "auth.json")
    BrowserContext.storage_state!(context, path: path)
    other = Browser.new_context!(browser, base_url: base_url, storage_state: path)
    page = BrowserContext.new_page!(other)
    Page.goto!(page, "/dashboard")
    Expect.to_have_url!(page, ~r"/dashboard$")
    BrowserContext.close!(other)
  end

  test "storage_state with IndexedDB", %{context: context} do
    page = BrowserContext.new_page!(context)
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

defmodule PlaywrightEx.Guides.TestingWithExUnit.TraceOnRerunTest do
  # "Trace on rerun": the guide's gated setup, with `TRACE` set as by `TRACE=1 mix test --failed`.
  # Not async: it sets an environment variable.
  use ExUnit.Case, async: false

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Guides.TestingWithExUnit.App
  alias PlaywrightEx.Guides.TestingWithExUnit.BrowserCase
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.Tracing

  setup_all %{module: module} do
    start_supervised!({PlaywrightEx.Supervisor, name: module})
    server = App.start!(Path.join(System.tmp_dir!(), "guide-app-#{System.unique_integer([:positive])}"))
    browser = PlaywrightEx.playwright(module) |> TestBrowser.browser_type() |> BrowserType.launch!()
    System.put_env("TRACE", "1")

    on_exit(fn ->
      System.delete_env("TRACE")
      dir = BrowserCase.artifacts_dir(__MODULE__, :"test signs up")
      assert File.exists?(Path.join(dir, "trace.zip"))
      File.rm_rf!(Path.join("tmp/test-results", inspect(__MODULE__)))
      Browser.close(browser)
    end)

    %{browser: browser, base_url: server.prefix}
  end

  setup %{browser: browser} = ctx do
    context = Browser.new_context!(browser, base_url: ctx.base_url)
    BrowserContext.set_default_timeout(context, 5_000)
    on_exit(fn -> BrowserContext.close(context) end)

    if System.get_env("TRACE") do
      tracing = BrowserContext.tracing(context)
      Tracing.start!(tracing, screenshots: true, snapshots: true, sources: true)

      on_exit(fn ->
        Tracing.stop(tracing, path: Path.join(BrowserCase.artifacts_dir(ctx.module, ctx.test), "trace.zip"))
      end)
    end

    %{context: context, page: BrowserContext.new_page!(context)}
  end

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
  end
end
