defmodule PlaywrightEx.Page.FrameFrameElementTest do
  @upstream "tests/page/frame-frame-element.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "should work @smoke", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame1 = attach_frame(page, "frame1", server.empty_page)
    attach_frame(page, "frame2", server.empty_page)
    frame3 = attach_frame(page, "frame3", server.empty_page)
    frame1handle1 = Page.query_selector!(page, "#frame1")
    frame1handle2 = Frame.frame_element!(frame1)
    frame3handle1 = Page.query_selector!(page, "#frame3")
    frame3handle2 = Frame.frame_element!(frame3)
    assert JSHandle.evaluate!(frame1handle1, "(a, b) => a === b", frame1handle2) == true
    assert JSHandle.evaluate!(frame3handle1, "(a, b) => a === b", frame3handle2) == true
    assert JSHandle.evaluate!(frame1handle1, "(a, b) => a === b", frame3handle1) == false
  end

  test "should work with contentFrame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame = attach_frame(page, "frame1", server.empty_page)
    handle = Frame.frame_element!(frame)
    content_frame = ElementHandle.content_frame!(handle)
    assert content_frame == frame
  end

  test "should work with frameset", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/frameset.html")
    frame_element1 = Page.query_selector!(page, "frame")
    frame = ElementHandle.content_frame!(frame_element1)
    frame_element2 = Frame.frame_element!(frame)
    assert JSHandle.evaluate!(frame_element1, "(a, b) => a === b", frame_element2) == true
  end

  test "should throw when detached", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame1 = attach_frame(page, "frame1", server.empty_page)
    Page.eval_on_selector!(page, "#frame1", "e => e.remove()")
    {:error, error} = Frame.frame_element(frame1)
    assert Exception.message(error) =~ "Frame has been detached."
  end

  test "should work inside closed shadow root", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <div id=framecontainer>
      </div>
      <script>
        const iframe = document.createElement('iframe');
        iframe.setAttribute('name', 'myframe');
        iframe.setAttribute('srcdoc', 'find me');
        const div = document.getElementById('framecontainer');
        const host = div.attachShadow({ mode: 'closed' });
        host.appendChild(iframe);
      </script>
    """)

    frame = Enum.at(Page.frames(page), 1)
    element = Frame.frame_element!(frame)
    assert ElementHandle.get_attribute!(element, "name") == "myframe"
  end

  test "should work inside declarative shadow root", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <div>
        <template shadowrootmode="open">
          <iframe name="myframe" srcdoc="<h1>Hi!</h1>"></iframe>
          <slot></slot>
        </template>
        <span>footer</span>
      </div>
    """)

    frame = Enum.at(Page.frames(page), 1)
    element = Frame.frame_element!(frame)
    assert ElementHandle.get_attribute!(element, "name") == "myframe"
  end
end
