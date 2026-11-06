defmodule PlaywrightEx.Page.PageAddStyleTagTest do
  @upstream "tests/page/page-add-style-tag.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  @background "window.getComputedStyle(document.querySelector('body')).getPropertyValue('background-color')"

  test "should throw an error if no options are provided", %{page: page} do
    # `page.addStyleTag('/injectedstyle.css')` (`@ts-ignore`): the facade only takes options, a
    # string carries none of `url`, `path`, `content`.
    {:error, error} = Page.add_style_tag(page)
    assert Exception.message(error) =~ "Provide an object with a `url`, `path` or `content` property"
  end

  test "should work with a url @smoke", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    style_handle = Page.add_style_tag!(page, url: "/injectedstyle.css")
    assert JSHandle.as_element(style_handle) != nil
    assert Page.evaluate!(page, @background) == "rgb(255, 0, 0)"
  end

  test "should throw an error if loading from url fail", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert {:error, error} = Page.add_style_tag(page, url: "/nonexistfile.js")
    assert error != nil
  end

  test "should work with a path", %{page: page, server: server, asset: asset} do
    Page.goto!(page, server.empty_page)
    style_handle = Page.add_style_tag!(page, path: asset.("injectedstyle.css"))
    assert JSHandle.as_element(style_handle) != nil
    assert Page.evaluate!(page, @background) == "rgb(255, 0, 0)"
  end

  test "should include sourceURL when path is provided", %{page: page, server: server, asset: asset} do
    Page.goto!(page, server.empty_page)
    Page.add_style_tag!(page, path: asset.("injectedstyle.css"))
    style_handle = Page.query_selector!(page, "style")
    style_content = Page.evaluate!(page, "style => style.innerHTML", style_handle)
    assert style_content =~ Path.join("assets", "injectedstyle.css")
  end

  test "should work with content", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    style_handle = Page.add_style_tag!(page, content: "body { background-color: green; }")
    assert JSHandle.as_element(style_handle) != nil
    assert Page.evaluate!(page, @background) == "rgb(0, 128, 0)"
  end

  test "should throw when added with content to the CSP page", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/csp.html")
    assert {:error, error} = Page.add_style_tag(page, content: "body { background-color: green; }")
    assert error
  end

  # it.skip(isAndroid, 'No cross-process on Android');  -- not Android
  test "should throw when added with URL to the CSP page", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/csp.html")
    assert {:error, error} = Page.add_style_tag(page, url: server.cross_process_prefix <> "/injectedstyle.css")
    assert error
  end
end
