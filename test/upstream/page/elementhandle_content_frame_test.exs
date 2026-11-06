defmodule PlaywrightEx.Page.ElementhandleContentFrameTest do
  @upstream "tests/page/elementhandle-content-frame.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page

  @moduletag :page

  test "should work", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    element_handle = Page.query_selector!(page, "#frame1")
    frame = ElementHandle.content_frame!(element_handle)
    assert frame == Enum.at(Page.frames(page), 1)
  end

  test "should work for cross-process iframes", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.cross_process_prefix <> "/empty.html")
    element_handle = Page.query_selector!(page, "#frame1")
    frame = ElementHandle.content_frame!(element_handle)
    assert frame == Enum.at(Page.frames(page), 1)
  end

  test "should work for cross-frame evaluations", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    frame = Enum.at(Page.frames(page), 1)
    element_handle = Frame.evaluate_handle!(frame, "() => window.top.document.querySelector('#frame1')")
    assert ElementHandle.content_frame!(element_handle) == frame
  end

  test "should return null for non-iframes", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    frame = Enum.at(Page.frames(page), 1)
    element_handle = Frame.evaluate_handle!(frame, "() => document.body")
    assert ElementHandle.content_frame!(element_handle) == nil
  end

  test "should return null for document.documentElement", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    frame = Enum.at(Page.frames(page), 1)
    element_handle = Frame.evaluate_handle!(frame, "() => document.documentElement")
    assert ElementHandle.content_frame!(element_handle) == nil
  end
end
