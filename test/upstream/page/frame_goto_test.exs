defmodule PlaywrightEx.Page.FrameGotoTest do
  @upstream "tests/page/frame-goto.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Response
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils

  @moduletag :page

  defp hang(_conn), do: Process.sleep(:infinity)

  test "should navigate subframes @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    assert Frame.url(Enum.at(Page.frames(page), 0)) =~ "/frames/one-frame.html"
    assert Frame.url(Enum.at(Page.frames(page), 1)) =~ "/frames/frame.html"

    response = Frame.goto!(Enum.at(Page.frames(page), 1), server.empty_page)
    assert Response.ok(response) == true
    assert Response.frame(response) == Enum.at(Page.frames(page), 1)
  end

  test "should reject when frame detaches", %{page: page, server: server, browser_name: browser_name} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")

    TestServer.set_route(server, "/one-style.css", &hang/1)
    css_request = TestServer.wait_for_request(server, "/one-style.css")
    frame = Enum.at(Page.frames(page), 1)
    navigation_promise = Task.async(fn -> Frame.goto(frame, server.prefix <> "/one-style.html") end)
    Task.await(css_request)

    Page.eval_on_selector!(page, "iframe", "frame => frame.remove()")
    {:error, error} = Task.await(navigation_promise)
    message = Exception.message(error)

    if browser_name == "chromium" do
      assert message =~ "net::ERR_ABORTED" or String.downcase(message) =~ "frame was detached"
    else
      assert String.downcase(message) =~ "frame was detached"
    end
  end

  test "should continue after client redirect", %{page: page, server: server, browser_name: browser_name} do
    # it.fixme(browserName === 'firefox' && !isBidi, 'script.js is requested before navigationCommitted arrives');
    if browser_name != "firefox" do
      TestServer.set_route(server, "/frames/script.js", &hang/1)
      url = server.prefix <> "/frames/child-redirect.html"
      {:error, error} = Page.goto(page, url, timeout: 5000, wait_until: :networkidle)
      assert Exception.message(error) =~ "page.goto: Timeout 5000ms exceeded."
      assert Exception.message(error) =~ ~s(navigating to "#{url}", waiting until "networkidle")
    end
  end

  test "should return matching responses", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    # Attach three frames.
    frames = [
      Utils.attach_frame(page, "frame1", server.empty_page),
      Utils.attach_frame(page, "frame2", server.empty_page),
      Utils.attach_frame(page, "frame3", server.empty_page)
    ]

    test = self()

    for i <- 0..2 do
      TestServer.set_route(server, "/#{i}.html", fn conn ->
        send(test, {:server_response, i, self()})

        receive do
          {:end, text} -> Plug.Conn.send_resp(conn, 200, text)
        end
      end)
    end

    navigations =
      for i <- 0..2 do
        request = TestServer.wait_for_request(server, "/#{i}.html")
        frame = Enum.at(frames, i)
        navigation = Task.async(fn -> Frame.goto!(frame, server.prefix <> "/#{i}.html") end)
        Task.await(request)
        navigation
      end

    server_responses =
      Map.new(0..2, fn i ->
        assert_receive {:server_response, ^i, pid}
        {i, pid}
      end)

    # Respond from server out-of-order.
    server_response_texts = ["AAA", "BBB", "CCC"]

    for i <- [1, 2, 0] do
      send(server_responses[i], {:end, Enum.at(server_response_texts, i)})
      response = Task.await(Enum.at(navigations, i))
      assert Response.frame(response) == Enum.at(frames, i)
      assert Response.text!(response) == Enum.at(server_response_texts, i)
    end
  end
end
