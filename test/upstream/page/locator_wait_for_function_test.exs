defmodule PlaywrightEx.Page.LocatorWaitForFunctionTest do
  @upstream "tests/page/locator-wait-for-function.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "should wait for an attribute to appear", %{page: page} do
    Page.set_content!(page, "<button id=toggle>Menu</button>")

    Page.evaluate!(
      page,
      "() => window.builtins.setTimeout(() => document.querySelector('#toggle').setAttribute('aria-expanded', 'true'), 1000)"
    )

    Locator.wait_for_function!(Page.locator(page, "#toggle"), "element => element.hasAttribute('aria-expanded')")
  end

  test "should return immediately when already truthy", %{page: page} do
    Page.set_content!(page, "<div id=target>yes</div>")
    assert Locator.wait_for_function!(Page.locator(page, "#target"), "element => element.textContent === 'yes'") == :ok
  end

  test "should accept ElementHandle arguments", %{page: page} do
    Page.set_content!(page, "<div id=a></div><div id=b>value</div>")
    handle = Page.query_selector!(page, "#b")

    Locator.wait_for_function!(
      Page.locator(page, "#a"),
      "(element, other) => other.textContent === 'value'",
      handle
    )
  end

  test "should accept string expression", %{page: page} do
    Page.set_content!(page, "<div id=target>yes</div>")
    Locator.wait_for_function!(Page.locator(page, "#target"), "element => element.textContent === 'yes'")
  end

  test "should resolve a promise returned by the predicate", %{page: page} do
    Page.set_content!(page, "<div id=target>yes</div>")
    Locator.wait_for_function!(Page.locator(page, "#target"), "async element => element.textContent === 'yes'")
  end

  test "should wait for element to appear and survive rerender", %{page: page} do
    Page.set_content!(page, "<span>nothing here</span>")

    Page.evaluate!(page, """
    () => {
      let count = 0;
      let prev = null;
      const tick = () => {
        ++count;
        const next = document.createElement('div');
        next.id = 'target';
        next.textContent = String(count);
        if (prev)
          prev.remove();
        document.body.appendChild(next);
        prev = next;
        if (count < 3)
          window.builtins.setTimeout(tick, 500);
      };
      window.builtins.setTimeout(tick, 500);
    }
    """)

    Locator.wait_for_function!(Page.locator(page, "#target"), "element => element.textContent === '3'")
  end

  test "should throw when predicate throws", %{page: page} do
    Page.set_content!(page, "<div id=target>no</div>")

    {:error, error} =
      Locator.wait_for_function(Page.locator(page, "#target"), """
      () => {
        throw new Error('oh my');
      }
      """)

    assert Exception.message(error) =~ "oh my"
  end

  test "should throw on strict mode violation", %{page: page} do
    Page.set_content!(page, "<div class=x>1</div><div class=x>2</div>")
    {:error, error} = Locator.wait_for_function(Page.locator(page, "div.x"), "() => true")
    assert Exception.message(error) =~ "strict mode violation"
  end

  test "should abort via signal", %{page: page} do
    Page.set_content!(page, "<div id=target>no</div>")
    controller = AbortController.new()

    task =
      Task.async(fn ->
        Locator.wait_for_function(
          Page.locator(page, "#target"),
          "element => element.textContent === 'yes'",
          nil,
          timeout: 0,
          signal: AbortController.signal(controller)
        )
      end)

    Page.wait_for_timeout!(page, 100)
    reason = %RuntimeError{message: "Aborted by user"}
    AbortController.abort(controller, reason)
    {:error, error} = Task.await(task, :infinity)
    assert error.name == "AbortError"
    assert error.cause == reason
  end

  test "should abort via already-aborted signal", %{page: page} do
    Page.set_content!(page, "<div id=target>no</div>")
    controller = AbortController.new()
    AbortController.abort(controller, "already aborted")

    {:error, error} =
      Locator.wait_for_function(Page.locator(page, "#target"), "() => true", nil,
        signal: AbortController.signal(controller)
      )

    assert error.name == "AbortError"
    assert error.cause == "already aborted"
  end
end
