defmodule PlaywrightEx.Library.WebmcpDisabledTest do
  @upstream "tests/library/webmcp-disabled.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.WebMCP

  @moduletag :page
  @moduletag skip: if(System.get_env("BROWSER") == "webkit", do: "WebKit does not implement WebMCP")
  # test.skip(({ isBidi }) => isBidi, 'WebMCP is not implemented over BiDi');

  test "should throw when the browser was launched without WebMCP", %{page: page, browser_name: browser_name} do
    {:error, error} = WebMCP.tools(Page.webmcp(page))
    assert Exception.message(error) =~ "WebMCP is not enabled."

    assert Exception.message(error) =~
             if(browser_name == "firefox", do: "dom.modelcontext.enabled", else: "--enable-features=WebMCP")
  end
end
