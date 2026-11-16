# Copyright 2018 Google Inc. All rights reserved.
# Modifications copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Page.LocatorEvaluateTest do
  @upstream "tests/page/locator-evaluate.spec.ts"
  use Playwright.UpstreamCase, async: true

  alias Playwright.Locator
  alias Playwright.Page

  @moduletag :page

  test "LO-084 should work @smoke", %{page: page} do
    Page.set_content!(
      page,
      ~s(<html><body><div class="tweet"><div class="like">100</div><div class="retweets">10</div></div></body></html>)
    )

    tweet = Page.locator(page, ".tweet .like")
    content = Locator.evaluate!(tweet, "node => node.innerText")
    assert content == "100"
  end

  test "LO-085 should retrieve content from subtree", %{page: page} do
    html_content = ~s(<div class="a">not-a-child-div</div><div id="myId"><div class="a">a-child-div</div></div>)
    Page.set_content!(page, html_content)
    element_handle = Page.locator(page, "#myId .a")
    content = Locator.evaluate!(element_handle, "node => node.innerText")
    assert content == "a-child-div"
  end

  test "LO-086 should work for all", %{page: page} do
    Page.set_content!(
      page,
      ~s(<html><body><div class="tweet"><div class="like">100</div><div class="like">10</div></div></body></html>)
    )

    tweet = Page.locator(page, ".tweet .like")
    content = Locator.evaluate_all!(tweet, "nodes => nodes.map(n => n.innerText)")
    assert content == ["100", "10"]
  end

  test "LO-087 should retrieve content from subtree for all", %{page: page} do
    html_content =
      ~s(<div class="a">not-a-child-div</div><div id="myId"><div class="a">a1-child-div</div><div class="a">a2-child-div</div></div>)

    Page.set_content!(page, html_content)
    element = Page.locator(page, "#myId .a")
    content = Locator.evaluate_all!(element, "nodes => nodes.map(n => n.innerText)")
    assert content == ["a1-child-div", "a2-child-div"]
  end

  test "LO-088 should not throw in case of missing selector for all", %{page: page} do
    html_content = ~s(<div class="a">not-a-child-div</div><div id="myId"></div>)
    Page.set_content!(page, html_content)
    element = Page.locator(page, "#myId .a")
    nodes_length = Locator.evaluate_all!(element, "nodes => nodes.length")
    assert nodes_length == 0
  end
end
