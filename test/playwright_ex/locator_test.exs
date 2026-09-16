defmodule PlaywrightEx.LocatorTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Locator

  test "evaluates a strictly resolved target inside a frame with an argument", %{frame: frame} do
    set_html(frame.guid, ~s(<iframe srcdoc="<input value='before'>"></iframe>))
    selector = "iframe >> internal:control=enter-frame >> input"

    assert {:ok, "after"} =
             Locator.evaluate(frame.guid,
               selector: selector,
               expression: "(element, value) => { element.value = value; return element.value; }",
               is_function: true,
               arg: "after",
               timeout: @timeout
             )
  end

  test "evaluation has no shared deadline with element resolution", %{frame: frame} do
    set_html(frame.guid, "<div></div>")
    eval(frame.guid, "() => { setTimeout(() => document.body.append(document.createElement('button')), 700); }")

    assert {:ok, "BUTTON"} =
             Locator.evaluate(frame.guid,
               selector: "button",
               expression:
                 "async element => { await new Promise(resolve => setTimeout(resolve, 800)); return element.tagName; }",
               is_function: true,
               timeout: 1_200
             )
  end

  test "missing element resolution still times out", %{frame: frame} do
    set_html(frame.guid, "<div></div>")

    assert {:error, %{error: %{name: "TimeoutError"}}} =
             Locator.evaluate(frame.guid,
               selector: "button",
               expression: "element => element.tagName",
               is_function: true,
               timeout: 100
             )
  end

  test "page closure interrupts evaluation without a timeout", %{frame: frame, page: page} do
    set_html(frame.guid, "<button></button>")

    task =
      Task.async(fn ->
        Locator.evaluate(frame.guid,
          selector: "button",
          expression: "() => { window.evaluationStarted = true; return new Promise(() => {}); }",
          is_function: true,
          timeout: @timeout
        )
      end)

    assert {:ok, _} =
             PlaywrightEx.Frame.wait_for_function(frame.guid,
               expression: "() => window.evaluationStarted === true",
               is_function: true,
               timeout: @timeout
             )

    assert {:ok, _} = PlaywrightEx.Page.close(page.guid, timeout: @timeout)
    assert {:error, %{error: %{name: "TargetClosedError"}}} = Task.await(task, @timeout)
  end

  test "preserves resolution and evaluation errors", %{frame: frame} do
    set_html(frame.guid, "<button>One</button><button>Two</button>")

    assert {:error, error} =
             Locator.evaluate(frame.guid,
               selector: "button",
               expression: "element => element.textContent",
               is_function: true,
               timeout: @timeout
             )

    assert inspect(error) =~ "strict mode violation"

    assert {:error, error} =
             Locator.evaluate(frame.guid,
               selector: "button >> nth=0",
               expression: "() => { throw new Error('evaluation failed') }",
               is_function: true,
               timeout: @timeout
             )

    assert inspect(error) =~ "evaluation failed"
  end
end
