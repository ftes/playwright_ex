defmodule PlaywrightEx.Page.ElementhandleBoundingBoxTest do
  @upstream "tests/page/elementhandle-bounding-box.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "should work", %{page: page, server: server} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/grid.html")
    element_handle = Page.query_selector!(page, ".box:nth-of-type(13)")
    box = ElementHandle.bounding_box!(element_handle)
    assert box == %{x: 100, y: 50, width: 50, height: 50}
  end

  test "should handle nested frames", %{page: page, server: server} do
    Page.set_viewport_size!(page, %{width: 616, height: 500})
    Page.goto!(page, server.prefix <> "/frames/nested-frames.html")

    nested_frame =
      page |> Page.frame_locator(~s([name="2frames"])) |> FrameLocator.frame_locator("[name=dos]")

    element_handle = nested_frame |> FrameLocator.locator("div") |> Locator.element_handle!()
    box = ElementHandle.bounding_box!(element_handle)
    assert box == %{x: 24, y: 224, width: 268, height: 18}
  end

  test "should get frame box", %{page: page} do
    Page.set_viewport_size!(page, %{width: 250, height: 250})

    Page.set_content!(page, """
    <style>
    body {
        display: flex;
        height: 500px;
        margin: 0px;
    }
    body iframe {
        flex-shrink: 1;
        border: 0;
        background-color: green;
    }
    </style>
    <iframe></iframe>
    """)

    element_handle = Page.query_selector!(page, "iframe")
    box = ElementHandle.bounding_box!(element_handle)
    assert box == %{x: 0, y: 0, width: 300, height: 500}
  end

  @tag skip: "not ported: mouse"
  test "should handle scroll offset and click"

  test "should return null for invisible elements", %{page: page} do
    Page.set_content!(page, ~s(<div style="display:none">hi</div>))
    element = Page.query_selector!(page, "div")
    assert ElementHandle.bounding_box!(element) == nil
  end

  test "should get bounding box of element inside a cross-origin iframe", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
    <div style="height:120px"></div>
    <iframe style="border:0;margin-left:30px;width:300px;height:200px" src="#{server.cross_process_prefix}/input/button.html"></iframe>
    """)

    frame = Enum.at(Page.frames(page), 1)
    button = Frame.wait_for_selector!(frame, "button")
    iframe_box = page |> Page.query_selector!("iframe") |> ElementHandle.bounding_box!()

    inner =
      JSHandle.evaluate!(button, "b => { const r = b.getBoundingClientRect(); return { x: r.left, y: r.top }; }")

    box = ElementHandle.bounding_box!(button)
    assert round(box.x) == round(iframe_box.x + inner["x"])
    assert round(box.y) == round(iframe_box.y + inner["y"])
  end

  test "should force a layout", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.set_content!(page, ~s(<div style="width: 100px; height: 100px">hello</div>))
    element_handle = Page.query_selector!(page, "div")
    Page.evaluate!(page, "element => element.style.height = '200px'", element_handle)
    box = ElementHandle.bounding_box!(element_handle)
    assert box == %{x: 8, y: 8, width: 100, height: 200}
  end

  test "should work with SVG nodes", %{page: page} do
    Page.set_content!(page, """
        <svg xmlns="http://www.w3.org/2000/svg" width="500" height="500">
          <rect id="theRect" x="30" y="50" width="200" height="300"></rect>
        </svg>
    """)

    element = Page.query_selector!(page, "#therect")
    pw_bounding_box = ElementHandle.bounding_box!(element)

    web_bounding_box =
      Page.evaluate!(
        page,
        """
        e => {
          const rect = e.getBoundingClientRect();
          return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
        }
        """,
        element
      )

    # JS objects come back with string keys.
    assert pw_bounding_box == Map.new(web_bounding_box, fn {k, v} -> {String.to_atom(k), v} end)
  end

  test "should work when inline box child is outside of viewport", %{page: page} do
    Page.set_content!(page, """
        <style>
        i {
          position: absolute;
          top: -1000px;
        }
        body {
          margin: 0;
          font-size: 12px;
        }
        </style>
        <span><i>woof</i><b>doggo</b></span>
    """)

    handle = Page.query_selector!(page, "span")
    box = ElementHandle.bounding_box!(handle)

    web_bounding_box =
      JSHandle.evaluate!(handle, """
      e => {
        const rect = e.getBoundingClientRect();
        return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
      }
      """)

    round = fn box ->
      %{
        x: round(box.x * 100),
        y: round(box.y * 100),
        width: round(box.width * 100),
        height: round(box.height * 100)
      }
    end

    web_bounding_box = Map.new(web_bounding_box, fn {k, v} -> {String.to_atom(k), v} end)
    assert round.(box) == round.(web_bounding_box)
  end
end
