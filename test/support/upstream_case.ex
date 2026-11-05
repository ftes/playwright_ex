defmodule PlaywrightEx.UpstreamCase do
  @moduledoc """
  Case template for tests mirrored from upstream `tests/` (see `PORTING.md`).

  Fixtures, as upstream's `tests/config/{baseTest,serverFixtures,browserTest}.ts` provide them.
  Upstream's worker-scoped fixtures are module-scoped here (one driver per test module):

    * `playwright`, `browser_name` (`BROWSER` env, default `"chromium"`), `browser_type`,
      `browser` (launched once per module)
    * `server`, `https_server` (`PlaywrightEx.TestServer`, reset before each test),
      `asset` (`asset.("file-to-upload.txt")` is its path under upstream `tests/assets`)
    * `context_factory` (`context_factory.(options)`; its contexts are closed after the test)
    * `context`, `page` for tests tagged `:page` (`@moduletag :page` for `pageTest` specs):
      upstream creates fixtures lazily, here a tag asks for them.
    * `request` (`playwright.request.newContext()`, disposed after the test) for tests tagged
      `:request`, or `request: options` (`newContext` options, for specs that override the fixture)
    * `create_user_data_dir` (`create_user_data_dir.()`, a fresh temp dir, removed after the test),
      `launch_persistent` (`launch_persistent.(options)` returns `%{context: _, page: _}`, closed
      after the test), `start_remote_server` (`start_remote_server.(kind, options)`: kind
      `"run-server"` (`PlaywrightEx.RemoteServer.RunServer`) or `"launchServer"`
      (`PlaywrightEx.RemoteServer`), closed after the test)
    * `launch_server` (`launch_server.(options)` for `browserType.launchServer(options)`:
      `{:ok, PlaywrightEx.RemoteServer.LaunchServer}` or `{:error, message}`, killed after the test)

  Tests call the public API (`PlaywrightEx.BrowserType`, ...), as upstream tests do.

  `test` skips a test that a rule in `test/upstream_not_ported.txt` rules out (`skip: "not
  ported: <reason>"`, over the test's own skip tags), so a bodiless test needs no tag of its own.
  See `Mix.PlaywrightEx.TestRegistry`.
  """
  use ExUnit.CaseTemplate

  alias Mix.PlaywrightEx.TestRegistry
  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.TestServer

  using do
    quote do
      import ExUnit.Case, only: [describe: 2]
      import PlaywrightEx.UpstreamCase, only: [test: 1, test: 2, test: 3]

      # Set `@upstream "tests/...spec.ts"` before `use`: `mix test --only upstream:<spec>`.
      @moduletag upstream: @upstream
      # tests/library/playwright.config.ts: `timeout: video || (darwin && x64) ? 60000 : 30000`
      # (we never record video); `test.slow()` triples it: `@tag timeout: @slow_timeout`.
      @moduletag timeout: PlaywrightEx.UpstreamCase.timeout()
      @slow_timeout 3 * PlaywrightEx.UpstreamCase.timeout()
    end
  end

  @doc "Upstream's per-test timeout (`tests/library/playwright.config.ts`)."
  def timeout do
    darwin_x64 =
      match?({:unix, :darwin}, :os.type()) and
        String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "x86_64")

    if darwin_x64, do: 60_000, else: 30_000
  end

  @doc "`ExUnit.Case.test/1`, skipped when a rule rules it out."
  defmacro test(message) do
    quote do
      PlaywrightEx.UpstreamCase.__not_ported__(__MODULE__, unquote(message))
      ExUnit.Case.test(unquote(message))
    end
  end

  @doc "`ExUnit.Case.test/3`, skipped when a rule rules it out."
  defmacro test(message, var \\ quote(do: _), contents) do
    quote do
      PlaywrightEx.UpstreamCase.__not_ported__(__MODULE__, unquote(message))
      ExUnit.Case.test(unquote(message), unquote(var), unquote(contents))
    end
  end

  @root Path.expand("../..", __DIR__)

  @doc false
  # Tags the next test `skip: "not ported: <reason>"` when a rule rules it out. The last `@tag`
  # wins, so the rule wins over the test's own skip tags.
  def __not_ported__(module, name) do
    # ExUnit keeps the current describe in `@ex_unit_describe` ({line, name, counter}).
    describe =
      case Module.get_attribute(module, :ex_unit_describe) do
        {_line, describe, _counter} -> describe
        _ -> nil
      end

    # Modules with no `@upstream` (our own tests on this case) have no registry tests.
    upstream = Module.get_attribute(module, :upstream)
    reason = upstream && TestRegistry.not_ported_reason(@root, upstream, describe, name)
    if reason, do: Module.put_attribute(module, :tag, skip: "not ported: " <> reason)
  end

  setup_all %{module: module} do
    # Upstream runs its tests with the driver "under test" (`window.builtins`, ...).
    start_supervised!({PlaywrightEx.Supervisor, name: module, env: [{"PWTEST_UNDER_TEST", "1"}]})
    playwright = PlaywrightEx.playwright(module)

    # Playwright Test's `_setupContextOptions` fixture: `playwright._defaultContextTimeout =
    # actionTimeout || 0` (likewise navigation): no action timeout, the test timeout bounds it.
    Api.call(nil, playwright, fn ->
      PlaywrightEx.Runtime.Heap.put(playwright, :_defaultContextTimeout, 0)
      PlaywrightEx.Runtime.Heap.put(playwright, :_defaultContextNavigationTimeout, 0)
    end)

    browser_name = TestBrowser.name()
    browser_type = TestBrowser.browser_type(playwright)

    assets = Path.join(PlaywrightEx.Upstream.ensure!(), "tests/assets")
    cached = Path.join(assets, "cached")

    server = TestServer.server(start_supervised!({TestServer, dir_path: assets}, id: :server))
    TestServer.enable_http_cache(server, cached)

    https_server =
      TestServer.server(
        start_supervised!({TestServer, dir_path: assets, ssl_options: TestServer.cert_options()}, id: :https_server)
      )

    TestServer.enable_http_cache(https_server, cached)

    %{
      playwright: playwright,
      browser_name: browser_name,
      browser_type: browser_type,
      browser: BrowserType.launch!(browser_type),
      server: server,
      https_server: https_server,
      asset: fn path -> Path.join([assets | String.split(path, "/")]) end
    }
  end

  setup %{server: server, https_server: https_server} do
    TestServer.reset(server)
    TestServer.reset(https_server)
    :ok
  end

  # Upstream restarts the worker after a failed test; here the module's driver lives on. Close
  # the contexts a test left open (say, a browser it launched and never closed), or one still
  # tracing would add its stacks to the traces of the next tests.
  setup %{playwright: playwright} do
    contexts = fn -> Api.call(nil, playwright, fn -> Client.Playwright._all_contexts(playwright) end) end
    before = contexts.()
    on_exit(fn -> for context <- contexts.() -- before, do: BrowserContext.close(context) end)
  end

  setup %{browser: browser} do
    {:ok, contexts} = Agent.start(fn -> [] end)

    context_factory = fn options ->
      context = Browser.new_context!(browser, options)
      Agent.update(contexts, &[context | &1])
      context
    end

    on_exit(fn ->
      for context <- Agent.get(contexts, & &1), do: BrowserContext.close(context)
      Agent.stop(contexts)
    end)

    %{context_factory: context_factory}
  end

  setup %{context_factory: context_factory} = tags do
    if tags[:page] do
      context = context_factory.([])
      %{context: context, page: BrowserContext.new_page!(context)}
    else
      :ok
    end
  end

  setup %{playwright: playwright} = tags do
    if options = tags[:request] do
      request = APIRequest.new_context!(Playwright.request(playwright), if(options == true, do: [], else: options))
      on_exit(fn -> APIRequestContext.dispose(request) end)
      %{request: request}
    else
      :ok
    end
  end

  setup %{browser_type: browser_type, browser_name: browser_name} do
    create_user_data_dir = fn ->
      dir = Path.join(System.tmp_dir!(), "playwright-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end

    launch_persistent = fn options ->
      user_data_dir = create_user_data_dir.()
      context = BrowserType.launch_persistent_context!(browser_type, user_data_dir, options)
      on_exit(fn -> BrowserContext.close(context) end)
      %{context: context, page: hd(BrowserContext.pages(context))}
    end

    # Upstream also waits 1 s after `server.close()` for its reused workers' browsers.
    start_remote_server = fn kind, options ->
      server =
        case kind do
          "run-server" -> PlaywrightEx.RemoteServer.RunServer.start(options)
          "launchServer" -> PlaywrightEx.RemoteServer._start(browser_type, options)
        end

      on_exit(fn -> PlaywrightEx.RemoteServer.PlaywrightServer.close(server) end)

      server
    end

    launch_server = fn options ->
      with {:ok, server} <- PlaywrightEx.RemoteServer.LaunchServer.start(browser_name, options) do
        on_exit(fn -> PlaywrightEx.RemoteServer.LaunchServer.kill(server) end)
        {:ok, server}
      end
    end

    %{
      create_user_data_dir: create_user_data_dir,
      launch_persistent: launch_persistent,
      start_remote_server: start_remote_server,
      launch_server: launch_server
    }
  end
end
