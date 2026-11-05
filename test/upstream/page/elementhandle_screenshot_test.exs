defmodule PlaywrightEx.Page.ElementhandleScreenshotTest do
  @upstream "tests/page/elementhandle-screenshot.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.UpstreamSnapshot
  import PlaywrightEx.Utils

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  # describe "element screenshot"

  test "should work", %{page: page, server: server} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/grid.html")
    Page.evaluate!(page, "() => window.scrollBy(50, 100)")
    element_handle = Page.query_selector!(page, ".box:nth-of-type(3)")
    screenshot = ElementHandle.screenshot!(element_handle)
    to_match_snapshot(screenshot, "screenshot-element-bounding-box.png")
  end

  test "should work with webp", %{page: page, server: server} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/grid.html")
    element_handle = Page.query_selector!(page, ".box:nth-of-type(3)")
    webp_image = decode_image(:webp, ElementHandle.screenshot!(element_handle, type: :webp))
    # The default webp screenshot is lossless, so it must decode to the exact same pixels as png.
    png_image = decode_image(:png, ElementHandle.screenshot!(element_handle, type: :png))
    assert webp_image.width == png_image.width
    assert webp_image.height == png_image.height
    assert webp_image.data == png_image.data
  end

  test "should work when main world busts JSON.stringify", %{page: page, server: server} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/grid.html")

    Page.evaluate!(page, """
    () => {
      window.scrollBy(50, 100);
      JSON.stringify = () => undefined;
    }
    """)

    element_handle = Page.query_selector!(page, ".box:nth-of-type(3)")
    screenshot = ElementHandle.screenshot!(element_handle)
    to_match_snapshot(screenshot, "screenshot-element-bounding-box.png")
  end

  test "should take into account padding and border", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})

    Page.set_content!(page, """
    <div style="height: 14px">oooo</div>
    <style>div {
      border: 2px solid blue;
      background: green;
      width: 50px;
      height: 50px;
    }
    </style>
    <div id="d"></div>
    """)

    element_handle = Page.query_selector!(page, "div#d")
    screenshot = ElementHandle.screenshot!(element_handle)
    to_match_snapshot(screenshot, "screenshot-element-padding-border.png")
  end

  test "should capture full element when larger than viewport in parallel", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})

    Page.set_content!(page, """
    <div style="height: 14px">oooo</div>
    <style>
    div.to-screenshot {
      border: 1px solid blue;
      width: 600px;
      height: 600px;
      margin-left: 50px;
    }
    ::-webkit-scrollbar{
      display: none;
    }
    </style>
    <div class="to-screenshot"></div>
    <div class="to-screenshot"></div>
    <div class="to-screenshot"></div>
    """)

    element_handles = Page.query_selector_all!(page, "div.to-screenshot")
    promises = Enum.map(element_handles, fn handle -> Task.async(fn -> ElementHandle.screenshot!(handle) end) end)
    screenshots = Task.await_many(promises, :infinity)
    to_match_snapshot(Enum.at(screenshots, 2), "screenshot-element-larger-than-viewport.png")

    verify_viewport(page, 500, 500)
  end

  test "should capture full element when larger than viewport", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})

    Page.set_content!(page, """
    <div style="height: 14px">oooo</div>
    <style>
    div.to-screenshot {
      border: 1px solid blue;
      width: 600px;
      height: 600px;
      margin-left: 50px;
    }
    ::-webkit-scrollbar{
      display: none;
    }
    </style>
    <div class="to-screenshot"></div>
    <div class="to-screenshot"></div>
    <div class="to-screenshot"></div>
    """)

    element_handle = Page.query_selector!(page, "div.to-screenshot")
    screenshot = ElementHandle.screenshot!(element_handle)
    to_match_snapshot(screenshot, "screenshot-element-larger-than-viewport.png")

    verify_viewport(page, 500, 500)
  end

  test "should scroll element into view", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})

    Page.set_content!(page, """
    <div style="height: 14px">oooo</div>
    <style>div.above {
      border: 2px solid blue;
      background: red;
      height: 1500px;
    }
    div.to-screenshot {
      border: 2px solid blue;
      background: green;
      width: 50px;
      height: 50px;
    }
    </style>
    <div class="above"></div>
    <div class="to-screenshot"></div>
    """)

    element_handle = Page.query_selector!(page, "div.to-screenshot")
    screenshot = ElementHandle.screenshot!(element_handle)
    to_match_snapshot(screenshot, "screenshot-element-scrolled-into-view.png")
  end

  test "should scroll 15000px into view", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})

    Page.set_content!(page, """
    <div style="height: 14px">oooo</div>
    <style>div.above {
      border: 2px solid blue;
      background: red;
      height: 15000px;
    }
    div.to-screenshot {
      border: 2px solid blue;
      background: green;
      width: 50px;
      height: 50px;
    }
    </style>
    <div class="above"></div>
    <div class="to-screenshot"></div>
    """)

    element_handle = Page.query_selector!(page, "div.to-screenshot")
    screenshot = ElementHandle.screenshot!(element_handle)
    to_match_snapshot(screenshot, "screenshot-element-scrolled-into-view.png")
  end

  test "should work with a rotated element", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})

    Page.set_content!(page, """
    <div style="position:absolute;
                                      top: 100px;
                                      left: 100px;
                                      width: 100px;
                                      height: 100px;
                                      background: green;
                                      transform: rotateZ(200deg);">&nbsp;</div>
    """)

    element_handle = Page.query_selector!(page, "div")
    screenshot = ElementHandle.screenshot!(element_handle)
    to_match_snapshot(screenshot, "screenshot-element-rotate.png")
  end

  test "should fail to screenshot a detached element", %{page: page} do
    Page.set_content!(page, "<h1>remove this</h1>")
    element_handle = Page.query_selector!(page, "h1")
    Page.evaluate!(page, "element => element.remove()", element_handle)
    {:error, screenshot_error} = ElementHandle.screenshot(element_handle)
    assert Exception.message(screenshot_error) =~ "Element is not attached to the DOM"
  end

  test "should timeout waiting for visible", %{page: page} do
    Page.set_content!(page, ~s(<div style="width: 50px; height: 0"></div>))
    div = Page.query_selector!(page, "div")
    {:error, error} = ElementHandle.screenshot(div, timeout: 3000)
    assert Exception.message(error) =~ "elementHandle.screenshot: Timeout 3000ms exceeded"
    assert Exception.message(error) =~ "element is not visible"
  end

  test "should wait for visible", %{page: page, server: server} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/grid.html")
    Page.evaluate!(page, "() => window.scrollBy(50, 100)")
    element_handle = Page.query_selector!(page, ".box:nth-of-type(3)")
    JSHandle.evaluate!(element_handle, "e => e.style.visibility = 'hidden'")
    promise = Task.async(fn -> ElementHandle.screenshot!(element_handle) end)
    rafraf(page, 10)
    # done is false
    assert Task.yield(promise, 0) == nil
    JSHandle.evaluate!(element_handle, "e => e.style.visibility = 'visible'")
    screenshot = Task.await(promise, :infinity)
    to_match_snapshot(screenshot, "screenshot-element-bounding-box.png")
  end

  test "should work for an element with fractional dimensions", %{page: page} do
    Page.set_content!(page, ~s(<div style="width:48.51px;height:19.8px;border:1px solid black;"></div>))
    element_handle = Page.query_selector!(page, "div")
    screenshot = ElementHandle.screenshot!(element_handle)
    to_match_snapshot(screenshot, "screenshot-element-fractional.png")
  end

  test "should work for an element with an offset", %{page: page} do
    Page.set_content!(
      page,
      ~s(<div style="position:absolute; top: 10.3px; left: 20.4px;width:50.3px;height:20.2px;border:1px solid black;"></div>)
    )

    element_handle = Page.query_selector!(page, "div")
    screenshot = ElementHandle.screenshot!(element_handle)
    to_match_snapshot(screenshot, "screenshot-element-fractional-offset.png")
  end

  test "should wait for element to stop moving", %{page: page, server: server} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/grid.html")
    element_handle = Page.query_selector!(page, ".box:nth-of-type(3)")
    JSHandle.evaluate!(element_handle, "e => e.classList.add('animation')")
    rafraf(page)
    screenshot = ElementHandle.screenshot!(element_handle)
    to_match_snapshot(screenshot, "screenshot-element-bounding-box.png")
  end

  test "should take screenshot of disabled button", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.set_content!(page, "<button disabled>Click me</button>")
    button = Page.query_selector!(page, "button")
    screenshot = ElementHandle.screenshot!(button)
    assert is_binary(screenshot)
  end

  @tag :tmp_dir
  test "path option should create subdirectories", %{page: page, server: server, tmp_dir: tmp_dir} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/grid.html")
    Page.evaluate!(page, "() => window.scrollBy(50, 100)")
    element_handle = Page.query_selector!(page, ".box:nth-of-type(3)")
    output_path = Path.join([tmp_dir, "these", "are", "directories", "screenshot.png"])
    ElementHandle.screenshot!(element_handle, path: output_path)
    to_match_snapshot(File.read!(output_path), "screenshot-element-bounding-box.png")
  end

  @tag :tmp_dir
  test "should prefer type over extension", %{page: page, server: server, tmp_dir: tmp_dir} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/grid.html")
    Page.evaluate!(page, "() => window.scrollBy(50, 100)")
    element_handle = Page.query_selector!(page, ".box:nth-of-type(3)")
    output_path = Path.join(tmp_dir, "file.png")
    buffer = ElementHandle.screenshot!(element_handle, path: output_path, type: :jpeg)
    assert binary_part(buffer, 0, 3) == <<0xFF, 0xD8, 0xFF>>
  end

  test "should not issue resize event", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/grid.html")
    test = self()

    Page.expose_function!(page, "resize", fn ->
      send(test, :resize_triggered)
      nil
    end)

    Page.evaluate!(page, """
    () => {
      window.addEventListener('resize', () => window.resize());
    }
    """)

    element_handle = Page.query_selector!(page, ".box:nth-of-type(3)")
    ElementHandle.screenshot!(element_handle)
    refute_received :resize_triggered
  end
end
