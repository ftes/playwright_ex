defmodule PlaywrightEx.Library.BrowsercontextClearcookiesTest do
  @upstream "tests/library/browsercontext-clearcookies.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  import PlaywrightEx.Utils, only: [poll: 2]

  @moduletag :page

  defp hostname(url), do: URI.parse(url).host

  test "should clear cookies", %{context: context, page: page, server: server} do
    Page.goto!(page, server.empty_page)
    BrowserContext.add_cookies!(context, [%{url: server.empty_page, name: "cookie1", value: "1"}])
    assert Page.evaluate!(page, "document.cookie") == "cookie1=1"
    BrowserContext.clear_cookies!(context)
    assert BrowserContext.cookies!(context) == []
    Page.reload!(page)
    assert Page.evaluate!(page, "document.cookie") == ""
  end

  test "should isolate cookies when clearing", %{context: context, server: server, browser: browser} do
    another_context = Browser.new_context!(browser)
    BrowserContext.add_cookies!(context, [%{url: server.empty_page, name: "page1cookie", value: "page1value"}])
    BrowserContext.add_cookies!(another_context, [%{url: server.empty_page, name: "page2cookie", value: "page2value"}])

    assert length(BrowserContext.cookies!(context)) == 1
    assert length(BrowserContext.cookies!(another_context)) == 1

    BrowserContext.clear_cookies!(context)
    assert BrowserContext.cookies!(context) == []
    assert length(BrowserContext.cookies!(another_context)) == 1

    BrowserContext.clear_cookies!(another_context)
    assert BrowserContext.cookies!(context) == []
    assert BrowserContext.cookies!(another_context) == []
    BrowserContext.close!(another_context)
  end

  test "should remove cookies by name", %{context: context, page: page, server: server} do
    BrowserContext.add_cookies!(context, [
      %{name: "cookie1", value: "1", domain: hostname(server.prefix), path: "/"},
      %{name: "cookie2", value: "2", domain: hostname(server.prefix), path: "/"}
    ])

    Page.goto!(page, server.prefix)
    assert Page.evaluate!(page, "document.cookie") == "cookie1=1; cookie2=2"
    BrowserContext.clear_cookies!(context, name: "cookie1")
    assert Page.evaluate!(page, "document.cookie") == "cookie2=2"
  end

  test "should remove cookies by name regex", %{context: context, page: page, server: server} do
    BrowserContext.add_cookies!(context, [
      %{name: "cookie1", value: "1", domain: hostname(server.prefix), path: "/"},
      %{name: "cookie2", value: "2", domain: hostname(server.prefix), path: "/"}
    ])

    Page.goto!(page, server.prefix)
    assert Page.evaluate!(page, "document.cookie") == "cookie1=1; cookie2=2"
    BrowserContext.clear_cookies!(context, name: ~r/coo.*1/)
    assert Page.evaluate!(page, "document.cookie") == "cookie2=2"
  end

  test "should remove cookies by domain", %{context: context, page: page, server: server} do
    BrowserContext.add_cookies!(context, [
      %{name: "cookie1", value: "1", domain: hostname(server.prefix), path: "/"},
      %{name: "cookie2", value: "2", domain: hostname(server.cross_process_prefix), path: "/"}
    ])

    Page.goto!(page, server.prefix)
    assert Page.evaluate!(page, "document.cookie") == "cookie1=1"
    Page.goto!(page, server.cross_process_prefix)
    assert Page.evaluate!(page, "document.cookie") == "cookie2=2"
    BrowserContext.clear_cookies!(context, domain: hostname(server.cross_process_prefix))
    assert Page.evaluate!(page, "document.cookie") == ""
    Page.goto!(page, server.prefix)
    assert Page.evaluate!(page, "document.cookie") == "cookie1=1"
  end

  test "should remove cookies by path", %{context: context, page: page, server: server} do
    BrowserContext.add_cookies!(context, [
      %{name: "cookie1", value: "1", domain: hostname(server.prefix), path: "/api/v1"},
      %{name: "cookie2", value: "2", domain: hostname(server.prefix), path: "/api/v2"},
      %{name: "cookie3", value: "3", domain: hostname(server.prefix), path: "/"}
    ])

    Page.goto!(page, server.prefix <> "/api/v1")
    assert Page.evaluate!(page, "document.cookie") == "cookie1=1; cookie3=3"
    BrowserContext.clear_cookies!(context, path: "/api/v1")
    assert Page.evaluate!(page, "document.cookie") == "cookie3=3"
    Page.goto!(page, server.prefix <> "/api/v2")
    assert Page.evaluate!(page, "document.cookie") == "cookie2=2; cookie3=3"
    Page.goto!(page, server.prefix <> "/")
    assert Page.evaluate!(page, "document.cookie") == "cookie3=3"
  end

  test "should remove cookies by name and domain", %{context: context, page: page, server: server} do
    BrowserContext.add_cookies!(context, [
      %{name: "cookie1", value: "1", domain: hostname(server.prefix), path: "/"},
      %{name: "cookie1", value: "1", domain: hostname(server.cross_process_prefix), path: "/"}
    ])

    Page.goto!(page, server.prefix)
    assert Page.evaluate!(page, "document.cookie") == "cookie1=1"
    BrowserContext.clear_cookies!(context, name: "cookie1", domain: hostname(server.prefix))
    assert Page.evaluate!(page, "document.cookie") == ""
    Page.goto!(page, server.cross_process_prefix)
    assert Page.evaluate!(page, "document.cookie") == "cookie1=1"
  end

  @tag skip:
         if(@browser_name == "webkit" and match?({:win32, _}, :os.type()),
           do:
             "upstream skip: cookieStore change events not supported on WebKit/Windows (curl backend lacks cookie change notifications)"
         )
  test "should not transiently delete non-matching cookies when filtering", %{
    context: context,
    page: page,
    server: server
  } do
    # it.skip(browserName === 'webkit' && isWindows), it.skip(isFrozenWebkit)  -- not our hosts
    BrowserContext.add_cookies!(context, [
      %{name: "keep_me", value: "1", domain: hostname(server.prefix), path: "/"},
      %{name: "delete_me", value: "2", domain: hostname(server.prefix), path: "/"}
    ])

    Page.goto!(page, server.prefix)

    events_handle =
      Page.evaluate_handle!(page, """
      () => {
        const events = [];
        cookieStore.addEventListener('change', event => {
          for (const changed of event.changed)
            events.push(`changed ${changed.name}`);
          for (const deleted of event.deleted)
            events.push(`deleted ${deleted.name}`);
        });
        return events;
      }
      """)

    BrowserContext.clear_cookies!(context, name: "delete_me")
    poll(fn -> JSHandle.json_value!(events_handle) end, &assert(&1 == ["deleted delete_me"]))
    assert Page.evaluate!(page, "document.cookie") == "keep_me=1"
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: Partitioned cookies (CHIPS) are Chromium-specific")
  test "should remove partitioned cookies by name", %{
    browser: browser,
    https_server: https_server
  } do
    context = Browser.new_context!(browser, ignore_https_errors: true)

    BrowserContext.add_cookies!(context, [
      %{
        name: "delete_me",
        value: "1",
        domain: https_server.hostname,
        path: "/",
        secure: true,
        sameSite: "None",
        partitionKey: "https://#{https_server.hostname}"
      },
      %{
        name: "keep_me",
        value: "2",
        domain: https_server.hostname,
        path: "/",
        secure: true,
        sameSite: "None",
        partitionKey: "https://#{https_server.hostname}"
      }
    ])

    before = BrowserContext.cookies!(context)

    assert [
             %{name: "delete_me", partitionKey: partition_key1},
             %{name: "keep_me", partitionKey: partition_key2}
           ] = before

    assert partition_key1 == "https://#{https_server.hostname}"
    assert partition_key2 == "https://#{https_server.hostname}"

    BrowserContext.clear_cookies!(context, name: "delete_me")
    assert [%{name: "keep_me", partitionKey: partition_key}] = BrowserContext.cookies!(context)
    assert partition_key == "https://#{https_server.hostname}"
    BrowserContext.close!(context)
  end

  test "should remove nameless cookies by empty name", %{context: context} do
    BrowserContext.add_cookies!(context, [
      %{name: "", value: "nameless", domain: "example.com", path: "/"},
      %{name: "session", value: "secret", domain: "example.com", path: "/"}
    ])

    BrowserContext.clear_cookies!(context, name: "")
    assert Enum.map(BrowserContext.cookies!(context), & &1.name) == ["session"]
  end
end
