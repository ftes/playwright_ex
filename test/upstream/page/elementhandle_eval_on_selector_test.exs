defmodule PlaywrightEx.Page.ElementhandleEvalOnSelectorTest do
  @upstream "tests/page/elementhandle-eval-on-selector.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "should work", %{page: page} do
    Page.set_content!(
      page,
      ~s(<html><body><div class="tweet"><div class="like">100</div><div class="retweets">10</div></div></body></html>)
    )

    tweet = Page.query_selector!(page, ".tweet")
    content = ElementHandle.eval_on_selector!(tweet, ".like", "node => node.innerText")
    assert content == "100"
  end

  test "should retrieve content from subtree", %{page: page} do
    html_content = ~s(<div class="a">not-a-child-div</div><div id="myId"><div class="a">a-child-div</div></div>)
    Page.set_content!(page, html_content)
    element_handle = Page.query_selector!(page, "#myId")
    content = ElementHandle.eval_on_selector!(element_handle, ".a", "node => node.innerText")
    assert content == "a-child-div"
  end

  test "should throw in case of missing selector", %{page: page} do
    html_content = ~s(<div class="a">not-a-child-div</div><div id="myId"></div>)
    Page.set_content!(page, html_content)
    element_handle = Page.query_selector!(page, "#myId")
    {:error, error} = ElementHandle.eval_on_selector(element_handle, ".a", "node => node.innerText")
    assert Exception.message(error) =~ ~s(elementHandle.$eval: Failed to find element matching selector ".a")
  end

  test "should work for all", %{page: page} do
    Page.set_content!(
      page,
      ~s(<html><body><div class="tweet"><div class="like">100</div><div class="like">10</div></div></body></html>)
    )

    tweet = Page.query_selector!(page, ".tweet")
    content = ElementHandle.eval_on_selector_all!(tweet, ".like", "nodes => nodes.map(n => n.innerText)")
    assert content == ["100", "10"]
  end

  test "should retrieve content from subtree for all", %{page: page} do
    html_content =
      ~s(<div class="a">not-a-child-div</div><div id="myId"><div class="a">a1-child-div</div><div class="a">a2-child-div</div></div>)

    Page.set_content!(page, html_content)
    element_handle = Page.query_selector!(page, "#myId")
    content = ElementHandle.eval_on_selector_all!(element_handle, ".a", "nodes => nodes.map(n => n.innerText)")
    assert content == ["a1-child-div", "a2-child-div"]
  end

  test "should not throw in case of missing selector for all", %{page: page} do
    html_content = ~s(<div class="a">not-a-child-div</div><div id="myId"></div>)
    Page.set_content!(page, html_content)
    element_handle = Page.query_selector!(page, "#myId")
    nodes_length = ElementHandle.eval_on_selector_all!(element_handle, ".a", "nodes => nodes.length")
    assert nodes_length == 0
  end
end
