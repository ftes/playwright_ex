defmodule PlaywrightEx.Page.ElementhandleWaitForElementStateTest do
  @upstream "tests/page/elementhandle-wait-for-element-state.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [rafraf: 1, rafraf: 2]

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime

  @moduletag :page

  defp give_it_a_chance_to_resolve(page), do: rafraf(page, 5)

  test "EH-112 should wait for visible", %{page: page} do
    Page.set_content!(page, "<div style='display:none'>content</div>")
    div = Page.query_selector!(page, "div")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state!(div, :visible) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(div, "div => div.style.display = 'block'")
    Runtime.Promise.await(task)
  end

  test "EH-113 should wait for already visible", %{page: page} do
    Page.set_content!(page, "<div>content</div>")
    div = Page.query_selector!(page, "div")
    ElementHandle.wait_for_element_state!(div, :visible)
  end

  test "EH-114 should timeout waiting for visible", %{page: page} do
    Page.set_content!(page, "<div style='display:none'>content</div>")
    div = Page.query_selector!(page, "div")
    {:error, error} = ElementHandle.wait_for_element_state(div, :visible, timeout: 1000)
    assert Exception.message(error) =~ "Timeout 1000ms exceeded"
  end

  test "EH-115 should throw waiting for visible when detached", %{page: page} do
    Page.set_content!(page, "<div style='display:none'>content</div>")
    div = Page.query_selector!(page, "div")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state(div, :visible) end)
    JSHandle.evaluate!(div, "div => div.remove()")
    {:error, error} = Runtime.Promise.await(task)
    assert Exception.message(error) =~ "Element is not attached to the DOM"
  end

  test "EH-116 should wait for hidden", %{page: page} do
    Page.set_content!(page, "<div>content</div>")
    div = Page.query_selector!(page, "div")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state!(div, :hidden) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(div, "div => div.style.display = 'none'")
    Runtime.Promise.await(task)
  end

  test "EH-117 should wait for already hidden", %{page: page} do
    Page.set_content!(page, "<div></div>")
    div = Page.query_selector!(page, "div")
    ElementHandle.wait_for_element_state!(div, :hidden)
  end

  test "EH-118 should wait for hidden when detached", %{page: page} do
    Page.set_content!(page, "<div>content</div>")
    div = Page.query_selector!(page, "div")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state!(div, :hidden) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(div, "div => div.remove()")
    Runtime.Promise.await(task)
  end

  test "EH-119 should throw waiting for enabled when detached", %{page: page} do
    Page.set_content!(page, "<button disabled>Target</button>")
    button = Page.query_selector!(page, "button")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state(button, :enabled) end)
    JSHandle.evaluate!(button, "button => button.remove()")
    {:error, error} = Runtime.Promise.await(task)
    assert Exception.message(error) =~ "Element is not attached to the DOM"
  end

  test "EH-120 should wait for aria enabled button", %{page: page} do
    Page.set_content!(page, "<button aria-disabled=true><span>Target</span></button>")
    span = Page.query_selector!(page, "text=Target")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state!(span, :enabled) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(span, "span => span.parentElement.setAttribute('aria-disabled', 'false')")
    Runtime.Promise.await(task)
  end

  test "EH-121 should wait for button with an aria-disabled parent", %{page: page} do
    Page.set_content!(page, ~s(<div role="group" aria-disabled=true><button><span>Target</span></button></div>))
    span = Page.query_selector!(page, "text=Target")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state!(span, :enabled) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(span, "span => span.parentElement.parentElement.setAttribute('aria-disabled', 'false')")
    Runtime.Promise.await(task)
  end

  test "EH-122 should wait for stable position", %{page: page, server: server} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43632' }
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")

    Page.eval_on_selector!(page, "button", """
    button => {
      button.style.transition = 'margin 10000ms linear 0s';
      button.style.marginLeft = '20000px';
    }
    """)

    # rafraf for Firefox to kick in the animation.
    rafraf(page)
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state!(button, :stable) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(button, "button => button.style.transition = ''")
    Runtime.Promise.await(task)
  end

  test "EH-123 should wait for editable input", %{page: page} do
    Page.set_content!(page, "<input readonly>")
    input = Page.query_selector!(page, "input")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state!(input, :editable) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(input, "input => input.readOnly = false")
    Runtime.Promise.await(task)
  end
end
