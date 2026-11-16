# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Library.WebmcpDisabledTest do
  @upstream "tests/library/webmcp-disabled.spec.ts"
  use Playwright.UpstreamCase, async: true

  alias Playwright.Page
  alias Playwright.WebMCP

  @moduletag :page
  @moduletag skip: if(System.get_env("BROWSER") == "webkit", do: "upstream skip: WebKit does not implement WebMCP")
  # test.skip(({ isBidi }) => isBidi, 'WebMCP is not implemented over BiDi');

  test "WM-015 should throw when the browser was launched without WebMCP", %{page: page, browser_name: browser_name} do
    {:error, error} = WebMCP.tools(Page.webmcp(page))
    assert Exception.message(error) =~ "WebMCP is not enabled."

    assert Exception.message(error) =~
             if(browser_name == "firefox", do: "dom.modelcontext.enabled", else: "--enable-features=WebMCP")
  end
end
