defmodule PlaywrightEx.Page.ElementhandleOwnerFrameTest do
  @upstream "tests/page/elementhandle-owner-frame.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page

  @moduletag :page

  test "should work", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    frame = Enum.at(Page.frames(page), 1)
    element_handle = Frame.evaluate_handle!(frame, "() => document.body")
    assert ElementHandle.owner_frame!(element_handle) == frame
  end

  test "should work for cross-process iframes", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.cross_process_prefix <> "/empty.html")
    frame = Enum.at(Page.frames(page), 1)
    element_handle = Frame.evaluate_handle!(frame, "() => document.body")
    assert ElementHandle.owner_frame!(element_handle) == frame
  end

  test "should work for document", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    frame = Enum.at(Page.frames(page), 1)
    element_handle = Frame.evaluate_handle!(frame, "() => document")
    assert ElementHandle.owner_frame!(element_handle) == frame
  end

  test "should work for iframe elements", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    frame = Page.main_frame(page)
    element_handle = Frame.evaluate_handle!(frame, "() => document.querySelector('#frame1')")
    assert ElementHandle.owner_frame!(element_handle) == frame
  end

  test "should work for cross-frame evaluations", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    frame = Page.main_frame(page)

    element_handle =
      Frame.evaluate_handle!(frame, "() => document.querySelector('iframe').contentWindow.document.body")

    assert ElementHandle.owner_frame!(element_handle) == hd(Frame.child_frames(frame))
  end

  test "should work for detached elements", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    div_handle =
      Page.evaluate_handle!(page, """
      () => {
        const div = document.createElement('div');
        document.body.appendChild(div);
        return div;
      }
      """)

    assert ElementHandle.owner_frame!(div_handle) == Page.main_frame(page)

    Page.evaluate!(page, """
    () => {
      const div = document.querySelector('div');
      document.body.removeChild(div);
    }
    """)

    assert ElementHandle.owner_frame!(div_handle) == Page.main_frame(page)
  end

  @tag skip: "not ported: waitForEvent"
  test "should work for adopted elements"
end
