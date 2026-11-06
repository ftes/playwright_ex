defmodule PlaywrightEx.Page.PageAddScriptTagTest do
  @upstream "tests/page/page-add-script-tag.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "should throw an error if no options are provided", %{page: page} do
    # `page.addScriptTag('/injectedfile.js')` (`@ts-ignore`): the facade only takes options, a
    # string carries none of `url`, `path`, `content`.
    {:error, error} = Page.add_script_tag(page)
    assert Exception.message(error) =~ "Provide an object with a `url`, `path` or `content` property"
  end

  test "should work with a url", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    script_handle = Page.add_script_tag!(page, url: "/injectedfile.js")
    assert JSHandle.as_element(script_handle) != nil
    assert Page.evaluate!(page, "() => window['__injected']") == 42
  end

  test "should work with a url and type=module", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.add_script_tag!(page, url: "/es6/es6import.js", type: "module")
    assert Page.evaluate!(page, "() => window['__es6injected']") == 42
  end

  test "should work with a path and type=module", %{page: page, server: server, asset: asset} do
    Page.goto!(page, server.empty_page)
    Page.add_script_tag!(page, path: asset.("es6/es6pathimport.js"), type: "module")
    Page.wait_for_function!(page, "window.__es6injected")
    assert Page.evaluate!(page, "() => window['__es6injected']") == 42
  end

  test "should work with a content and type=module", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.add_script_tag!(page,
      content: "import num from '/es6/es6module.js';window.__es6injected = num;",
      type: "module"
    )

    Page.wait_for_function!(page, "window.__es6injected")
    assert Page.evaluate!(page, "() => window['__es6injected']") == 42
  end

  test "should throw an error if loading from url fail", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert {:error, error} = Page.add_script_tag(page, url: "/nonexistfile.js")
    assert error != nil
  end

  test "should work with a path", %{page: page, server: server, asset: asset} do
    Page.goto!(page, server.empty_page)
    script_handle = Page.add_script_tag!(page, path: asset.("injectedfile.js"))
    assert JSHandle.as_element(script_handle) != nil
    assert Page.evaluate!(page, "() => window['__injected']") == 42
  end

  @tag skip: if(System.get_env("BROWSER", "chromium") == "webkit", do: "upstream skip: webkit")
  test "should include sourceURL when path is provided", %{page: page, server: server, asset: asset} do
    Page.goto!(page, server.empty_page)
    Page.add_script_tag!(page, path: asset.("injectedfile.js"))
    result = Page.evaluate!(page, "() => window['__injectedError'].stack")
    assert result =~ Path.join("assets", "injectedfile.js")
  end

  test "should work with content", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    script_handle = Page.add_script_tag!(page, content: ~s|window["__injected"] = 35;|)
    assert JSHandle.as_element(script_handle) != nil
    assert Page.evaluate!(page, "() => window['__injected']") == 35
  end

  test "should throw when added with content to the CSP page", %{page: page, server: server} do
    # Firefox fires onload for blocked script before it issues the CSP console error.
    Page.goto!(page, server.prefix <> "/csp.html")
    assert {:error, error} = Page.add_script_tag(page, content: ~s|window["__injected"] = 35;|)
    assert error
  end

  test "should throw when added with URL to the CSP page", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/csp.html")
    assert {:error, error} = Page.add_script_tag(page, url: server.cross_process_prefix <> "/injectedfile.js")
    assert error
  end

  test "should throw a nice error when the request fails", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    url = server.prefix <> "/this_does_not_exist.js"
    {:error, error} = Page.add_script_tag(page, url: url)
    assert Exception.message(error) =~ url
  end
end
