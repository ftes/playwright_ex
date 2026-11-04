defmodule PlaywrightEx.Page.LocatorMisc2Test do
  @upstream "tests/page/locator-misc-2.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "should press @smoke", %{page: page} do
    Page.set_content!(page, "<input type='text' />")
    Locator.press!(Page.locator(page, "input"), "h")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "h"
  end

  test "should scroll into view", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/offscreenbuttons.html")

    for i <- 0..10 do
      button = Page.locator(page, "#btn#{i}")

      before =
        Locator.evaluate!(button, "button => { return button.getBoundingClientRect().right - window.innerWidth; }")

      assert before == 10 * i
      Locator.scroll_into_view_if_needed!(button)

      after_ =
        Locator.evaluate!(button, "button => { return button.getBoundingClientRect().right - window.innerWidth; }")

      assert after_ <= 0 == true
      Page.evaluate!(page, "() => window.scrollTo(0, 0)")
    end
  end

  test "should scroll zero-sized element into view", %{page: page} do
    Page.set_content!(page, """
      <style>
        html,body { margin: 0; padding: 0; }
        ::-webkit-scrollbar { display: none; }
        * { scrollbar-width: none; }
      </style>
      <div style="height: 2000px; text-align: center; border: 10px solid blue;">
        <h1>SCROLL DOWN</h1>
      </div>
      <div id=lazyload style="font-size:75px; background-color: green;"></div>
      <script>
        const lazyLoadElement = document.querySelector('#lazyload');
        const observer = new IntersectionObserver((entries) => {
          if (entries.some(entry => entry.isIntersecting)) {
            lazyLoadElement.textContent = 'LAZY LOADED CONTENT';
            lazyLoadElement.style.height = '20px';
            observer.disconnect();
          }
        });
        observer.observe(lazyLoadElement);
      </script>
    """)

    assert Locator.bounding_box!(Page.locator(page, "#lazyload")) == %{x: 0, y: 2020, width: 1280, height: 0}
    Locator.scroll_into_view_if_needed!(Page.locator(page, "#lazyload"))
    Expect.to_have_text!(Page.locator(page, "#lazyload"), "LAZY LOADED CONTENT")
    assert Locator.bounding_box!(Page.locator(page, "#lazyload")) == %{x: 0, y: 720, width: 1280, height: 20}
  end

  test "should select textarea", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    textarea = Page.locator(page, "textarea")
    Locator.evaluate!(textarea, "textarea => textarea.value = 'some value'")
    Locator.select_text!(textarea)
    assert Page.evaluate!(page, "() => window.getSelection().toString()") == "some value"
  end

  test "should type", %{page: page} do
    Page.set_content!(page, "<input type='text' />")
    Locator.type!(Page.locator(page, "input"), "hello")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "hello"
  end

  test "should pressSequentially", %{page: page} do
    Page.set_content!(page, "<input type='text' />")
    Locator.press_sequentially!(Page.locator(page, "input"), "hello")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "hello"
  end

  @tag skip: "not ported: toMatchSnapshot"
  test "should take screenshot"

  test "should return bounding box", %{page: page, server: server} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/grid.html")
    element = Page.locator(page, ".box:nth-of-type(13)")
    box = Locator.bounding_box!(element)
    assert box == %{x: 100, y: 50, width: 50, height: 50}
  end

  test "should waitFor", %{page: page} do
    Page.set_content!(page, "<div></div>")
    locator = Page.locator(page, "span")
    promise = Task.async(fn -> Locator.wait_for!(locator) end)
    Page.eval_on_selector!(page, "div", "div => div.innerHTML = '<span>target</span>'")
    Task.await(promise)
    Expect.to_have_text!(locator, "target")
  end

  test "should waitFor hidden", %{page: page} do
    Page.set_content!(page, "<div><span>target</span></div>")
    locator = Page.locator(page, "span")
    promise = Task.async(fn -> Locator.wait_for!(locator, state: :hidden) end)
    Page.eval_on_selector!(page, "div", "div => div.innerHTML = ''")
    Task.await(promise)
  end

  test "should combine visible with other selectors", %{page: page} do
    Page.set_content!(page, """
    <div>
    <div class="item" style="display: none">Hidden data0</div>
    <div class="item">visible data1</div>
    <div class="item" style="display: none">Hidden data1</div>
    <div class="item">visible data2</div>
    <div class="item" style="display: none">Hidden data1</div>
    <div class="item">visible data3</div>
    </div>
    """)

    locator = page |> Page.locator(".item >> visible=true") |> Locator.nth(1)
    Expect.to_have_text!(locator, "visible data2")
    Expect.to_have_text!(Page.locator(page, ".item >> visible=true >> text=data3"), "visible data3")
  end

  @items """
  <div>
    <div class="item" style="display: none">Hidden data0</div>
    <div class="item">visible data1</div>
    <div class="item" style="display: none">Hidden data1</div>
    <div class="item">visible data2</div>
    <div class="item" style="display: none">Hidden data2</div>
    <div class="item">visible data3</div>
    </div>
  """

  test "should support filter(visible)", %{page: page} do
    Page.set_content!(page, @items)
    locator = page |> Page.locator(".item") |> Locator.filter(visible: true) |> Locator.nth(1)
    Expect.to_have_text!(locator, "visible data2")

    Expect.to_have_text!(
      page |> Page.locator(".item") |> Locator.filter(visible: true) |> Locator.get_by_text("data3"),
      "visible data3"
    )

    Expect.to_have_text!(
      page |> Page.locator(".item") |> Locator.filter(visible: false) |> Locator.get_by_text("data1"),
      "Hidden data1"
    )
  end

  test "should support visible()", %{page: page} do
    Page.set_content!(page, @items)
    locator = page |> Page.locator(".item") |> Locator.visible() |> Locator.nth(1)
    Expect.to_have_text!(locator, "visible data2")

    Expect.to_have_text!(
      page |> Page.locator(".item") |> Locator.visible() |> Locator.get_by_text("data3"),
      "visible data3"
    )

    Expect.to_have_count!(page |> Page.locator(".item") |> Locator.visible(), 3)
  end

  test "locator.count should work with deleted Map in main world", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/11254' });
    Page.evaluate!(page, "Map = 1")
    Locator.count!(Page.locator(page, "#searchResultTableDiv .x-grid3-row"))
    Expect.to_have_count!(Page.locator(page, "#searchResultTableDiv .x-grid3-row"), 0)
  end

  test "Locator.locator() and FrameLocator.locator() should accept locator", %{page: page} do
    Page.set_content!(page, """
      <div><input value=outer></div>
      <iframe srcdoc="<div><input value=inner></div>"></iframe>
    """)

    input_locator = Page.locator(page, "input")
    assert Locator.input_value!(input_locator) == "outer"
    assert page |> Page.locator("div") |> Locator.locator(input_locator) |> Locator.input_value!() == "outer"

    assert page |> Page.frame_locator("iframe") |> FrameLocator.locator(input_locator) |> Locator.input_value!() ==
             "inner"

    assert page
           |> Page.frame_locator("iframe")
           |> FrameLocator.locator("div")
           |> Locator.locator(input_locator)
           |> Locator.input_value!() == "inner"

    div_locator = Page.locator(page, "div")
    assert div_locator |> Locator.locator("input") |> Locator.input_value!() == "outer"

    assert page
           |> Page.frame_locator("iframe")
           |> FrameLocator.locator(div_locator)
           |> Locator.locator("input")
           |> Locator.input_value!() == "inner"
  end

  test "should fill programmatically enabled textarea", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/36307' }
    Page.set_content!(page, """
      <button>Enable</button>
      <form>
        <textarea id="text" disabled></textarea>
      </form>
      <script>
        document.querySelector('button').addEventListener('click', () => {
          document.querySelector('#text').disabled = false;
        });
      </script>
    """)

    Locator.click!(Page.locator(page, "button"))
    Locator.fill!(Page.locator(page, "#text"), "Hello")
    Expect.to_have_value!(Page.locator(page, "#text"), "Hello")
  end

  test "press should throw on unknown keys", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/36697' }
    Page.set_content!(page, "<input type='text' value='hello' />")
    locator = Page.get_by_role(page, "textbox")
    assert {:error, error} = Locator.press(locator, "NotARealKey")
    assert Exception.message(error) =~ ~s(Unknown key: "NotARealKey")
    assert {:error, error} = Locator.press(locator, "ё")
    assert Exception.message(error) =~ ~s(Unknown key: "ё")
    assert {:error, error} = Locator.press(locator, "😊")
    assert Exception.message(error) =~ ~s(Unknown key: "😊")
  end
end
