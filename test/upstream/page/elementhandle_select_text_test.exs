defmodule PlaywrightEx.Page.ElementhandleSelectTextTest do
  @upstream "tests/page/elementhandle-select-text.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "should select textarea", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    textarea = Page.query_selector!(page, "textarea")
    JSHandle.evaluate!(textarea, "textarea => textarea.value = 'some value'")
    ElementHandle.select_text!(textarea)
    assert Page.evaluate!(page, "() => window.getSelection().toString()") == "some value"
  end

  test "should select input", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    input = Page.query_selector!(page, "input")
    JSHandle.evaluate!(input, "input => input.value = 'some value'")
    ElementHandle.select_text!(input)
    assert Page.evaluate!(page, "() => window.getSelection().toString()") == "some value"
  end

  test "should select plain div", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    div = Page.query_selector!(page, "div.plain")
    ElementHandle.select_text!(div)
    assert Page.evaluate!(page, "() => window.getSelection().toString()") == "Plain div"
  end

  test "should timeout waiting for invisible element", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    textarea = Page.query_selector!(page, "textarea")
    JSHandle.evaluate!(textarea, "e => e.style.display = 'none'")
    {:error, error} = ElementHandle.select_text(textarea, timeout: 3000)
    assert Exception.message(error) =~ "element is not visible"
  end

  test "should wait for visible", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    textarea = Page.query_selector!(page, "textarea")
    JSHandle.evaluate!(textarea, "textarea => textarea.value = 'some value'")
    JSHandle.evaluate!(textarea, "e => e.style.display = 'none'")
    task = Task.async(fn -> ElementHandle.select_text!(textarea, timeout: 3000) end)
    Page.wait_for_timeout!(page, 1000)
    assert Task.yield(task, 0) == nil
    JSHandle.evaluate!(textarea, "e => e.style.display = 'block'")
    Task.await(task, :infinity)
  end
end
