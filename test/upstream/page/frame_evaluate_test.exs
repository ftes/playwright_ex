defmodule PlaywrightEx.Page.FrameEvaluateTest do
  @upstream "tests/page/frame-evaluate.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [attach_frame: 3, detach_frame: 2]

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page

  @moduletag :page

  test "FR-001 should have different execution contexts", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    assert length(Page.frames(page)) == 2
    Frame.evaluate!(Enum.at(Page.frames(page), 0), "() => window['FOO'] = 'foo'")
    Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window['FOO'] = 'bar'")
    assert Frame.evaluate!(Enum.at(Page.frames(page), 0), "() => window['FOO']") == "foo"
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window['FOO']") == "bar"
  end

  test "FR-002 should have correct execution contexts @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    assert length(Page.frames(page)) == 2
    assert Frame.evaluate!(Enum.at(Page.frames(page), 0), "() => document.body.textContent.trim()") == ""

    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => document.body.textContent.trim()") ==
             "Hi, I'm frame"
  end

  test "FR-003 should dispose context on navigation"

  test "FR-004 should dispose context on cross-origin navigation"

  test "FR-005 should execute after cross-site navigation", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    main_frame = Page.main_frame(page)
    assert Frame.evaluate!(main_frame, "() => window.location.href") =~ server.empty_page
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    assert Frame.evaluate!(main_frame, "() => window.location.href") =~ server.cross_process_prefix
  end

  test "FR-006 should not allow cross-frame js handles", %{page: page, server: server} do
    # Upstream to-do: this should actually be possible because frames script each other,
    # but protocol implementations do not support this. For now, assume current
    # behavior.
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")

    handle =
      Page.evaluate_handle!(page, """
      () => {
        const iframe = document.querySelector('iframe');
        const foo = { bar: 'baz' };
        iframe.contentWindow['__foo'] = foo;
        return foo;
      }
      """)

    child_frame = page |> Page.main_frame() |> Frame.child_frames() |> Enum.at(0)
    child_result = Frame.evaluate!(child_frame, "() => window['__foo']")
    assert child_result == %{"bar" => "baz"}
    {:error, error} = Frame.evaluate(child_frame, "foo => foo.bar", handle)
    assert Exception.message(error) =~ "JSHandles can be evaluated only in the context they were created!"
  end

  test "FR-007 should allow cross-frame element handles", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    body_handle = page |> Page.main_frame() |> Frame.child_frames() |> Enum.at(0) |> Frame.query_selector!("body")
    result = Page.evaluate!(page, "body => body.innerHTML", body_handle)
    assert String.trim(result) == "<div>Hi, I'm frame</div>"
  end

  test "FR-008 should not allow cross-frame element handles when frames do not script each other", %{
    page: page,
    server: server
  } do
    Page.goto!(page, server.empty_page)
    frame = attach_frame(page, "frame1", server.cross_process_prefix <> "/empty.html")
    body_handle = Frame.query_selector!(frame, "body")
    {:error, error} = Page.evaluate(page, "body => body.innerHTML", body_handle)
    assert Exception.message(error) =~ "Unable to adopt element handle from a different document"
  end

  test "FR-009 should throw for detached frames", %{page: page, server: server} do
    frame1 = attach_frame(page, "frame1", server.empty_page)
    detach_frame(page, "frame1")
    {:error, error} = Frame.evaluate(frame1, "() => 7 * 8")
    assert Exception.message(error) =~ "frame.evaluate: Frame was detached"
  end

  test "FR-010 should be isolated between frames", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    assert length(Page.frames(page)) == 2
    [frame1, frame2] = Page.frames(page)
    assert frame1 != frame2

    Task.await_many(
      [
        Task.async(fn -> Frame.evaluate!(frame1, "() => window['a'] = 1") end),
        Task.async(fn -> Frame.evaluate!(frame2, "() => window['a'] = 2") end)
      ],
      :infinity
    )

    [a1, a2] =
      Task.await_many(
        [
          Task.async(fn -> Frame.evaluate!(frame1, "() => window['a']") end),
          Task.async(fn -> Frame.evaluate!(frame2, "() => window['a']") end)
        ],
        :infinity
      )

    assert a1 == 1
    assert a2 == 2
  end

  test "FR-011 should work in iframes that failed initial navigation", %{page: page, browser_name: browser_name} do
    Page.set_content!(
      page,
      """
      <meta http-equiv="Content-Security-Policy" content="script-src 'none';">
      <iframe src='javascript:""'></iframe>
      """,
      wait_until: :domcontentloaded
    )

    Page.evaluate!(page, """
    () => {
      const iframe = document.querySelector('iframe');
      const div = iframe.contentDocument.createElement('div');
      iframe.contentDocument.body.appendChild(div);
    }
    """)

    assert Frame.url(Enum.at(Page.frames(page), 1)) == if(browser_name == "webkit", do: "about:blank", else: "")
    # Main world should work.
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window.location.href") == "about:blank"
    # Utility world should work.
    assert Frame.query_selector!(Enum.at(Page.frames(page), 1), "div")
  end

  test "FR-012 should work in iframes that interrupted initial javascript url navigation", %{page: page, server: server} do
    # Chromium does not report isolated world for the iframe.
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      const iframe = document.createElement('iframe');
      iframe.src = 'javascript:""';
      document.body.appendChild(iframe);
      iframe.contentDocument.open();
      iframe.contentDocument.write('<div>hello</div>');
      iframe.contentDocument.close();
    }
    """)

    # Main world should work.
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window.top.location.href") == server.empty_page
    # Utility world should work.
    assert Frame.query_selector!(Enum.at(Page.frames(page), 1), "div")
  end

  test "FR-013 evaluateHandle should work", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    main_frame = Page.main_frame(page)
    window_handle = Frame.evaluate_handle!(main_frame, "() => window")
    assert window_handle
  end
end
