defmodule PlaywrightEx.Page.PageSetContentTest do
  @upstream "tests/page/page-set-content.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.TimeoutError

  @moduletag :page

  @expected_output "<html><head></head><body><div>hello</div></body></html>"

  defp hang(_conn), do: Process.sleep(:infinity)

  test "PA-020 should work @smoke", %{page: page} do
    Page.set_content!(page, "<div>hello</div>")
    result = Page.content!(page)
    assert result == @expected_output
  end

  test "PA-021 should work with domcontentloaded", %{page: page} do
    Page.set_content!(page, "<div>hello</div>", wait_until: :domcontentloaded)
    result = Page.content!(page)
    assert result == @expected_output
  end

  test "PA-022 should work with commit", %{page: page} do
    Page.set_content!(page, "<div>hello</div>", wait_until: :commit)
    result = Page.content!(page)
    assert result == @expected_output
  end

  test "PA-023 should work with doctype", %{page: page} do
    doctype = "<!DOCTYPE html>"
    Page.set_content!(page, "#{doctype}<div>hello</div>")
    result = Page.content!(page)
    assert result == "#{doctype}#{@expected_output}"
  end

  test "PA-024 should work with HTML 4 doctype", %{page: page} do
    doctype =
      ~s(<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" ) <>
        ~s("http://www.w3.org/TR/html4/strict.dtd">)

    Page.set_content!(page, "#{doctype}<div>hello</div>")
    result = Page.content!(page)
    assert result == "#{doctype}#{@expected_output}"
  end

  test "PA-025 should include shadow roots", %{page: page} do
    html =
      ~s(<!DOCTYPE html><html lang="en"><head></head><body><div id="host"><template shadowrootmode="open"><div id="nested"><template shadowrootmode="open"><span>nested</span></template><slot></slot></div></template><span>light</span></div><div id="closed"></div></body></html>)

    # Closed shadow roots are not accessible from script and are never serialized.
    Page.set_content!(
      page,
      String.replace(
        html,
        ~s(<div id="closed">),
        ~s(<div id="closed"><template shadowrootmode="closed"><span>closed</span></template>),
        global: false
      )
    )

    assert Page.content!(page) ==
             ~s(<!DOCTYPE html><html lang="en"><head></head><body><div id="host"><span>light</span></div><div id="closed"></div></body></html>)

    assert Page.content!(page, include_shadow: true) == html
  end

  test "PA-026 should respect timeout", %{page: page, server: server} do
    img_path = "/img.png"
    # stall for image
    TestServer.set_route(server, img_path, &hang/1)
    {:error, error} = Page.set_content(page, ~s(<img src="#{server.prefix <> img_path}"></img>), timeout: 1)
    assert %TimeoutError{} = error
  end

  test "PA-027 should respect default navigation timeout", %{page: page, server: server} do
    Page.set_default_navigation_timeout(page, 1)
    img_path = "/img.png"
    # stall for image
    TestServer.set_route(server, img_path, &hang/1)
    {:error, error} = Page.set_content(page, ~s(<img src="#{server.prefix <> img_path}"></img>))
    assert Exception.message(error) =~ "page.setContent: Timeout 1ms exceeded."
    assert %TimeoutError{} = error
  end

  test "PA-028 should await resources to load", %{page: page, server: server} do
    test = self()
    img_path = "/img.png"

    TestServer.set_route(server, img_path, fn conn ->
      send(test, {:img_response, self()})

      receive do
        :end -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    img_request = TestServer.wait_for_request(server, img_path)

    content_promise =
      Runtime.Promise.async(fn ->
        Page.set_content!(page, ~s(<img src="#{server.prefix <> img_path}"></img>))
        send(test, :loaded)
      end)

    Task.await(img_request, :infinity)
    refute_received :loaded
    assert_receive {:img_response, img_response}
    send(img_response, :end)
    Runtime.Promise.await(content_promise)
  end

  test "PA-029 should work fast enough", %{page: page} do
    for _ <- 1..20, do: Page.set_content!(page, "<div>yo</div>")
  end

  test "PA-030 should work with tricky content", %{page: page} do
    Page.set_content!(page, "<div>hello world</div>" <> "\x7F")
    assert Page.eval_on_selector!(page, "div", "div => div.textContent") == "hello world"
  end

  test "PA-031 should work with accents", %{page: page} do
    Page.set_content!(page, "<div>aberración</div>")
    assert Page.eval_on_selector!(page, "div", "div => div.textContent") == "aberración"
  end

  test "PA-032 should work with emojis", %{page: page} do
    Page.set_content!(page, "<div>🐥</div>")
    assert Page.eval_on_selector!(page, "div", "div => div.textContent") == "🐥"
  end

  test "PA-033 should work with newline", %{page: page} do
    Page.set_content!(page, "<div>\n</div>")
    assert Page.eval_on_selector!(page, "div", "div => div.textContent") == "\n"
  end

  test "PA-034 content() should throw nice error during navigation", %{page: page, server: server} do
    for timeout <- 0..180//20 do
      Page.set_content!(page, "<div>hello</div>")
      promise = Runtime.Promise.async(fn -> Page.goto!(page, server.empty_page) end)
      Page.wait_for_timeout!(page, timeout)
      content_or_error = Page.content(page)
      Runtime.Promise.await(promise)
      empty_output = "<html><head></head><body></body></html>"

      case content_or_error do
        {:ok, content} when content in [@expected_output, empty_output] ->
          :ok

        {:error, error} ->
          assert Exception.message(error) =~
                   "Unable to retrieve content because the page is navigating and changing the content."
      end
    end
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream fixme: there is no utility context")
  test "PA-035 should return empty content there is no iframe src", %{page: page} do
    # it.fixme(browserName === 'webkit', 'there is no utility context');
    Page.set_content!(page, ~s[<iframe src="javascript:console.log(1)"></iframe>])
    assert length(Page.frames(page)) == 2
    assert Frame.content!(Enum.at(Page.frames(page), 1)) == "<html><head></head><body></body></html>"
  end

  test "PA-036 should handle timeout properly"

  test "PA-037 should handle timeout properly 2"
end
