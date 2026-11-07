defmodule PlaywrightEx.Library.Firefox.LauncherTest do
  @upstream "tests/library/firefox/launcher.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag skip: if(System.get_env("BROWSER", "chromium") != "firefox", do: "upstream skip: Firefox only")

  @proxy_prefs %{
    "network.proxy.type" => 1,
    "network.proxy.ssl" => "127.0.0.1",
    "network.proxy.ssl_port" => 3333
  }

  test "FF-001 should pass firefox user preferences", %{browser_type: browser_type} do
    browser = BrowserType.launch!(browser_type, firefox_user_prefs: @proxy_prefs)
    page = Browser.new_page!(browser)
    {:error, error} = Page.goto(page, "https://example.com")
    assert Exception.message(error) =~ "NS_ERROR_PROXY_CONNECTION_REFUSED"
    Browser.close!(browser)
  end

  test "FF-002 should pass firefox user preferences in persistent", %{launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(firefox_user_prefs: @proxy_prefs)
    {:error, error} = Page.goto(page, "https://example.com")
    assert Exception.message(error) =~ "NS_ERROR_PROXY_CONNECTION_REFUSED"
  end

  @tag :tmp_dir
  test "FF-003 should support custom firefox policies", %{browser_type: browser_type, asset: asset, tmp_dir: tmp_dir} do
    policies = %{
      "policies" => %{
        "Certificates" => %{
          "Install" => [asset.("client-certificates/server/server_cert.pem")]
        }
      }
    }

    policies_path = Path.join(tmp_dir, "policies.json")
    File.write!(policies_path, JSON.encode!(policies))

    port = 13_122

    server =
      TestServer.server(
        start_supervised!(
          {TestServer,
           dir_path: asset.(""),
           port: port,
           ssl_options: [
             keyfile: to_charlist(asset.("client-certificates/client/localhost/localhost.key")),
             certfile: to_charlist(asset.("client-certificates/client/localhost/localhost.pem"))
           ]},
          id: :policies_server
        )
      )

    # inheritAndCleanEnv: the process env without the reserved CI and test-runner variables.
    env =
      System.get_env()
      |> Map.drop(~w(CI BUILD_URL CI_COMMIT_SHA CI_JOB_URL CI_PROJECT_URL GITHUB_ACTIONS GITHUB_REPOSITORY
        GITHUB_RUN_ID GITHUB_SERVER_URL GITHUB_SHA GITHUB_EVENT_PATH PW_TEST_HTML_REPORT_OPEN PLAYWRIGHT_HTML_OPEN
        PW_TEST_DEBUG_REPORTERS PW_TEST_REPORTER PW_TEST_REPORTER_WS_ENDPOINT PW_TEST_SOURCE_TRANSFORM
        PW_TEST_SOURCE_TRANSFORM_SCOPE PWTEST_BOT_NAME PWTEST_SHARD_WEIGHTS TEST_WORKER_INDEX TEST_PARALLEL_INDEX
        NODE_OPTIONS))
      |> Map.put("PLAYWRIGHT_FIREFOX_POLICIES_JSON", policies_path)

    browser = BrowserType.launch!(browser_type, env: env)

    page = Browser.new_page!(browser)
    Page.goto!(page, server.prefix <> "/frames/frame.html")
    Expect.to_have_text!(Page.locator(page, "body"), "Hi, I'm frame")
    Browser.close!(browser)
    TestServer.stop(server)
  end
end
