defmodule PlaywrightEx.Page.LocatorWaitForFunctionTest do
  @upstream "tests/page/locator-wait-for-function.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime

  @moduletag :page

  test "LO-183 should wait for an attribute to appear", %{page: page} do
    Page.set_content!(page, "<button id=toggle>Menu</button>")

    Page.evaluate!(
      page,
      "() => window.builtins.setTimeout(() => document.querySelector('#toggle').setAttribute('aria-expanded', 'true'), 1000)"
    )

    Locator.wait_for_function!(Page.locator(page, "#toggle"), "element => element.hasAttribute('aria-expanded')")
  end

  test "LO-184 should return immediately when already truthy", %{page: page} do
    Page.set_content!(page, "<div id=target>yes</div>")
    assert Locator.wait_for_function!(Page.locator(page, "#target"), "element => element.textContent === 'yes'") == :ok
  end

  test "LO-185 should accept ElementHandle arguments", %{page: page} do
    Page.set_content!(page, "<div id=a></div><div id=b>value</div>")
    handle = Page.query_selector!(page, "#b")

    Locator.wait_for_function!(
      Page.locator(page, "#a"),
      "(element, other) => other.textContent === 'value'",
      handle
    )
  end

  test "LO-186 should accept string expression", %{page: page} do
    Page.set_content!(page, "<div id=target>yes</div>")
    Locator.wait_for_function!(Page.locator(page, "#target"), "element => element.textContent === 'yes'")
  end

  test "LO-187 should resolve a promise returned by the predicate", %{page: page} do
    Page.set_content!(page, "<div id=target>yes</div>")
    Locator.wait_for_function!(Page.locator(page, "#target"), "async element => element.textContent === 'yes'")
  end

  test "LO-188 should wait for element to appear and survive rerender", %{page: page} do
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

  test "LO-189 should throw when predicate throws", %{page: page} do
    Page.set_content!(page, "<div id=target>no</div>")

    {:error, error} =
      Locator.wait_for_function(Page.locator(page, "#target"), """
      () => {
        throw new Error('oh my');
      }
      """)

    assert Exception.message(error) =~ "oh my"
  end

  test "LO-190 should throw on strict mode violation", %{page: page} do
    Page.set_content!(page, "<div class=x>1</div><div class=x>2</div>")
    {:error, error} = Locator.wait_for_function(Page.locator(page, "div.x"), "() => true")
    assert Exception.message(error) =~ "strict mode violation"
  end

  test "LO-191 should abort via signal", %{page: page} do
    Page.set_content!(page, "<div id=target>no</div>")
    controller = AbortController.new()

    task =
      Runtime.Promise.async(fn ->
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
    {:error, error} = Runtime.Promise.await(task)
    assert error.name == "AbortError"
    assert error.cause == reason
  end

  test "LO-192 should abort via already-aborted signal", %{page: page} do
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
