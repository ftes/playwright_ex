defmodule PlaywrightEx.Page.FrameHierarchyTest do
  @upstream "tests/page/frame-hierarchy.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  import PlaywrightEx.Utils, only: [attach_frame: 3, detach_frame: 2]

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp dump_frames(frame, indentation \\ "") do
    description = Frame.url(frame)
    description = if Frame.name(frame) != "", do: description <> " (" <> Frame.name(frame) <> ")", else: description
    child_frames = frame |> Frame.child_frames() |> Enum.sort_by(&{Frame.url(&1), Frame.name(&1)})
    [indentation <> description | Enum.flat_map(child_frames, &dump_frames(&1, "    " <> indentation))]
  end

  # `frames.push(frame)` in listeners: they send `{tag, frame}` to the test process.
  defp received(tag, acc \\ []) do
    receive do
      {^tag, x} -> received(tag, [x | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "FR-024 should handle nested frames @smoke", %{page: page, server: server} do
    # it.skip(isAndroid, 'No cross-process on Android');
    # it.skip(isBidi, 'frame.name() is racy with BiDi');

    Page.goto!(page, server.prefix <> "/frames/nested-frames.html")

    assert dump_frames(Page.main_frame(page)) == [
             "#{server.prefix}/frames/nested-frames.html",
             "    #{server.prefix}/frames/frame.html (aframe)",
             "    #{server.prefix}/frames/two-frames.html (2frames)",
             "        #{server.prefix}/frames/frame.html (dos)",
             "        #{server.prefix}/frames/frame.html (uno)"
           ]
  end

  test "FR-025 should send events when frames are manipulated dynamically", %{page: page, server: server} do
    me = self()
    Page.goto!(page, server.empty_page)
    # validate frameattached events
    Page.on(page, :frame_attached, &send(me, {:attached, &1}))
    attach_frame(page, "frame1", "./assets/frame.html")
    attached_frames = received(:attached)
    assert length(attached_frames) == 1
    assert Frame.url(hd(attached_frames)) =~ "/assets/frame.html"

    # validate framenavigated events
    Page.on(page, :frame_navigated, &send(me, {:navigated, &1}))

    Page.evaluate!(page, """
    () => {
      const frame = document.getElementById('frame1');
      frame.src = './empty.html';
      return new Promise(x => frame.onload = x);
    }
    """)

    navigated_frames = received(:navigated)
    assert length(navigated_frames) == 1
    assert Frame.url(hd(navigated_frames)) == server.empty_page

    # validate framedetached events
    Page.on(page, :frame_detached, &send(me, {:detached, &1}))
    detach_frame(page, "frame1")
    detached_frames = received(:detached)
    assert length(detached_frames) == 1
    assert Frame.is_detached(hd(detached_frames)) == true
  end

  test "FR-026 should send \"framenavigated\" when navigating on anchor URLs", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame_navigated = Page.wait_for_event(page, :frame_navigated)
    Page.goto!(page, server.empty_page <> "#foo")
    Promise.await!(frame_navigated)
    assert Page.url(page) == server.empty_page <> "#foo"
  end

  test "FR-027 should persist mainFrame on cross-process navigation", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    main_frame = Page.main_frame(page)
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    assert Page.main_frame(page) == main_frame
  end

  test "FR-028 should not send attach/detach events for main frame", %{page: page, server: server} do
    me = self()
    Page.on(page, :frame_attached, fn _frame -> send(me, :has_events) end)
    Page.on(page, :frame_detached, fn _frame -> send(me, :has_events) end)
    Page.goto!(page, server.empty_page)
    refute_received :has_events
  end

  test "FR-029 should detach child frames on navigation", %{page: page, server: server} do
    me = self()
    Page.on(page, :frame_attached, &send(me, {:attached, &1}))
    Page.on(page, :frame_detached, &send(me, {:detached, &1}))
    Page.on(page, :frame_navigated, &send(me, {:navigated, &1}))
    Page.goto!(page, server.prefix <> "/frames/nested-frames.html")
    assert length(received(:attached)) == 4
    assert received(:detached) == []
    assert length(received(:navigated)) == 5

    Page.goto!(page, server.empty_page)
    assert received(:attached) == []
    assert length(received(:detached)) == 4
    assert length(received(:navigated)) == 1
  end

  test "FR-030 should support framesets", %{page: page, server: server} do
    me = self()
    Page.on(page, :frame_attached, &send(me, {:attached, &1}))
    Page.on(page, :frame_detached, &send(me, {:detached, &1}))
    Page.on(page, :frame_navigated, &send(me, {:navigated, &1}))
    Page.goto!(page, server.prefix <> "/frames/frameset.html")
    assert length(received(:attached)) == 4
    assert received(:detached) == []
    assert length(received(:navigated)) == 5

    Page.goto!(page, server.empty_page)
    assert received(:attached) == []
    assert length(received(:detached)) == 4
    assert length(received(:navigated)) == 1
  end

  test "FR-031 should report frame from-inside shadow DOM", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/shadow.html")

    Page.evaluate!(
      page,
      """
      async url => {
        const frame = document.createElement('iframe');
        frame.src = url;
        document.body.shadowRoot.appendChild(frame);
        await new Promise(x => frame.onload = x);
      }
      """,
      server.empty_page
    )

    assert length(Page.frames(page)) == 2
    assert Frame.url(Enum.at(Page.frames(page), 1)) == server.empty_page
  end

  test "FR-032 should report frame.name()", %{page: page, server: server} do
    # it.skip(isBidi, 'frame.name() is racy with BiDi');

    attach_frame(page, "theFrameId", server.empty_page)

    Page.evaluate!(
      page,
      """
      url => {
        const frame = document.createElement('iframe');
        frame.name = 'theFrameName';
        frame.src = url;
        document.body.appendChild(frame);
        return new Promise(x => frame.onload = x);
      }
      """,
      server.empty_page
    )

    assert Frame.name(Enum.at(Page.frames(page), 0)) == ""
    assert Frame.name(Enum.at(Page.frames(page), 1)) == "theFrameId"
    assert Frame.name(Enum.at(Page.frames(page), 2)) == "theFrameName"
  end

  test "FR-033 should report frame.parent()", %{page: page, server: server} do
    attach_frame(page, "frame1", server.empty_page)
    attach_frame(page, "frame2", server.empty_page)
    assert Frame.parent_frame(Enum.at(Page.frames(page), 0)) == nil
    assert Frame.parent_frame(Enum.at(Page.frames(page), 1)) == Page.main_frame(page)
    assert Frame.parent_frame(Enum.at(Page.frames(page), 2)) == Page.main_frame(page)
  end

  test "FR-034 should report different frame instance when frame re-attaches", %{page: page, server: server} do
    frame1 = attach_frame(page, "frame1", server.empty_page)

    Page.evaluate!(page, """
    () => {
      window['frame'] = document.querySelector('#frame1');
      window['frame'].remove();
    }
    """)

    assert Frame.is_detached(frame1) == true
    frame_attached = Page.wait_for_event(page, :frame_attached)
    Page.evaluate!(page, "() => document.body.appendChild(window['frame'])")
    frame2 = Promise.await!(frame_attached)
    assert Frame.is_detached(frame2) == false
    refute frame1 == frame2
  end

  @tag skip: if(@browser_name == "firefox", do: "upstream skip: firefox")
  test "FR-035 should refuse to display x-frame-options:deny iframe", %{page: page, server: server} do
    # it.skip(browserName === 'firefox');
    TestServer.set_route(server, "/x-frame-options-deny.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.put_resp_header("x-frame-options", "DENY")
      |> Plug.Conn.send_resp(
        200,
        ~s(<!DOCTYPE html><html><head><title>login</title></head><body style="background-color: red;"><p>dangerous login page</p></body></html>)
      )
    end)

    Page.goto!(page, server.empty_page)
    me = self()

    Page.on(page, :console, fn msg ->
      if ConsoleMessage.text(msg) =~ ~r/Refused to display/i, do: send(me, {:refusal_text, ConsoleMessage.text(msg)})
    end)

    Page.set_content!(page, ~s(<iframe src="#{server.cross_process_prefix}/x-frame-options-deny.html"></iframe>))
    assert_receive {:refusal_text, refusal_text}, 10_000
    assert refusal_text =~ ~r/Refused to display .* in a frame because it set 'X-Frame-Options' to 'deny'./i
  end

  test "FR-036 should return frame.page()", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    assert Frame.page(Page.main_frame(page)) == page
    assert page |> Page.main_frame() |> Frame.child_frames() |> hd() |> Frame.page() == page
  end
end
