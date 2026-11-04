defmodule PlaywrightEx.Page.ElementhandleScreenshotTest do
  @upstream "tests/page/elementhandle-screenshot.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Page

  @moduletag :page

  # describe "element screenshot"

  @tag skip: "not ported: toMatchSnapshot"
  test "should work"

  @tag skip: "not ported: decodeWebp / PNG decoding"
  test "should work with webp"

  @tag skip: "not ported: toMatchSnapshot"
  test "should work when main world busts JSON.stringify"

  @tag skip: "not ported: toMatchSnapshot"
  test "should take into account padding and border"

  @tag skip: "not ported: toMatchSnapshot"
  test "should capture full element when larger than viewport in parallel"

  @tag skip: "not ported: toMatchSnapshot"
  test "should capture full element when larger than viewport"

  @tag skip: "not ported: toMatchSnapshot"
  test "should scroll element into view"

  @tag skip: "not ported: toMatchSnapshot"
  test "should scroll 15000px into view"

  @tag skip: "not ported: toMatchSnapshot"
  test "should work with a rotated element"

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

  @tag skip: "not ported: toMatchSnapshot"
  test "should wait for visible"

  @tag skip: "not ported: toMatchSnapshot"
  test "should work for an element with fractional dimensions"

  @tag skip: "not ported: toMatchSnapshot"
  test "should work for an element with an offset"

  @tag skip: "not ported: toMatchSnapshot"
  test "should wait for element to stop moving"

  test "should take screenshot of disabled button", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.set_content!(page, "<button disabled>Click me</button>")
    button = Page.query_selector!(page, "button")
    screenshot = ElementHandle.screenshot!(button)
    assert is_binary(screenshot)
  end

  @tag skip: "not ported: toMatchSnapshot"
  test "path option should create subdirectories"

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

  @tag skip: "not ported: exposeFunction"
  test "should not issue resize event"
end
