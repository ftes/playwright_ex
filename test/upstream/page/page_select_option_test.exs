defmodule PlaywrightEx.Page.PageSelectOptionTest do
  @upstream "tests/page/page-select-option.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.Utils

  @moduletag :page

  defp give_it_a_chance_to_resolve(page), do: Utils.rafraf(page, 5)

  defp all_unselected(page),
    do: Page.eval_on_selector!(page, "select", "select => Array.from(select.options).every(option => !option.selected)")

  @add_scarlet """
  select => {
    const option = document.createElement('option');
    option.value = 'scarlet';
    option.textContent = 'Scarlet';
    select.appendChild(option);
  }
  """

  test "SO-001 should select single option @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", "blue")
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["blue"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["blue"]
  end

  test "SO-002 should select single option by value", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", %{value: "blue"})
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["blue"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["blue"]
  end

  test "SO-003 should fall back to selecting by label", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", "Blue")
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["blue"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["blue"]
  end

  test "SO-004 should select single option by label", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", %{label: "Indigo"})
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["indigo"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["indigo"]
  end

  test "SO-005 should select single option by label with html whitespace", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", %{label: "HTML"})
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["html"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["html"]
  end

  test "SO-006 should select single option by handle", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", Page.query_selector!(page, "[id=whiteOption]"))
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["white"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["white"]
  end

  test "SO-007 should select single option by index", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", %{index: 2})
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["brown"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["brown"]
  end

  test "SO-008 should select single option by multiple attributes", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", %{value: "green", label: "Green"})
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["green"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["green"]
  end

  test "SO-009 should not select single option when some attributes do not match", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.eval_on_selector!(page, "select", "s => s.value = undefined")

    case Page.select_option(page, "select", %{value: "green", label: "Brown"}, timeout: 1000) do
      {:error, e} -> assert Exception.message(e) =~ "Timeout"
      {:ok, _} -> :ok
    end

    assert Page.evaluate!(page, "() => document.querySelector('select').value") == ""
  end

  test "SO-010 should select only first option", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", ["blue", "green", "red"])
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["blue"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["blue"]
  end

  test "SO-011 should not throw when select causes navigation", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")

    Page.eval_on_selector!(
      page,
      "select",
      "select => select.addEventListener('input', () => window.location.href = '/empty.html')"
    )

    navigation = Page.wait_for_navigation(page)
    Page.select_option!(page, "select", "blue")
    Promise.await!(navigation)
    assert Page.url(page) =~ "empty.html"
  end

  test "SO-012 should select multiple options", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.evaluate!(page, "() => window['makeMultiple']()")
    Page.select_option!(page, "select", ["blue", "green", "red"])
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["blue", "green", "red"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["blue", "green", "red"]
  end

  test "SO-013 should select multiple options with attributes", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.evaluate!(page, "() => window['makeMultiple']()")
    Page.select_option!(page, "select", [%{value: "blue"}, %{label: "Green"}, %{index: 4}])
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["blue", "gray", "green"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["blue", "gray", "green"]
  end

  test "SO-014 should respect event bubbling", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", "blue")
    assert Page.evaluate!(page, "() => window['result'].onBubblingInput") == ["blue"]
    assert Page.evaluate!(page, "() => window['result'].onBubblingChange") == ["blue"]
  end

  test "SO-015 should throw when element is not a <select>", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    {:error, error} = Page.select_option(page, "body", "")
    assert Exception.message(error) =~ "Element is not a <select> element"
  end

  test "SO-016 should return [] on no matched values", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    result = Page.select_option!(page, "select", [])
    assert result == []
  end

  test "SO-017 should return an array of matched values", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.evaluate!(page, "() => window['makeMultiple']()")
    result = Page.select_option!(page, "select", ["blue", "black", "magenta"])
    assert Enum.all?(result, &(&1 in ["blue", "black", "magenta"]))
  end

  test "SO-018 should return an array of one element when multiple is not set", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    result = Page.select_option!(page, "select", ["42", "blue", "black", "magenta"])
    assert length(result) == 1
  end

  test "SO-019 should return [] on no values", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    result = Page.select_option!(page, "select", [])
    assert result == []
  end

  test "SO-020 should not allow null items", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.evaluate!(page, "() => window['makeMultiple']()")
    {:error, error} = Page.select_option(page, "select", ["blue", :null, "black", "magenta"])
    assert Exception.message(error) =~ "options[1]: expected object, got null"
  end

  test "SO-021 should unselect with null", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.evaluate!(page, "() => window['makeMultiple']()")
    result = Page.select_option!(page, "select", ["blue", "black", "magenta"])
    assert Enum.all?(result, &(&1 in ["blue", "black", "magenta"]))
    Page.select_option!(page, "select", :null)
    assert all_unselected(page) == true
  end

  test "SO-022 should deselect all options when passed no values for a multiple select", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.evaluate!(page, "() => window['makeMultiple']()")
    Page.select_option!(page, "select", ["blue", "black", "magenta"])
    Page.select_option!(page, "select", [])
    assert all_unselected(page) == true
  end

  test "SO-023 should deselect all options when passed no values for a select without multiple", %{
    page: page,
    server: server
  } do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.select_option!(page, "select", ["blue", "black", "magenta"])
    Page.select_option!(page, "select", [])
    assert all_unselected(page) == true
  end

  test "SO-024 should throw if passed wrong types", %{page: page} do
    Page.set_content!(page, ~s(<select><option value="12"/></select>))

    # @ts-expect-error cannot select numbers
    {:error, error} = Page.select_option(page, "select", 12)
    assert Exception.message(error) =~ "options[0]: expected object, got number"

    # @ts-expect-error cannot select numbers
    {:error, error} = Page.select_option(page, "select", %{value: 12})
    assert Exception.message(error) =~ "options[0].value: expected string, got number"

    # @ts-expect-error cannot select numbers
    {:error, error} = Page.select_option(page, "select", %{label: 12})
    assert Exception.message(error) =~ "options[0].label: expected string, got number"

    # @ts-expect-error cannot select string indices
    {:error, error} = Page.select_option(page, "select", %{index: "12"})
    assert Exception.message(error) =~ "options[0].index: expected integer, got string"
  end

  # @see https://github.com/GoogleChrome/puppeteer/issues/3327
  test "SO-025 should work when re-defining top-level Event class", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.evaluate!(page, "() => window.Event = null")
    Page.select_option!(page, "select", "blue")
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["blue"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["blue"]
  end

  test "SO-026 should wait for option to be present", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    select_promise = Runtime.Promise.async(fn -> Page.select_option!(page, "select", "scarlet") end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(select_promise)
    Page.eval_on_selector!(page, "select", @add_scarlet)
    items = Runtime.Promise.await(select_promise)
    assert items == ["scarlet"]
  end

  test "SO-027 should wait for option index to be present", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    len = Page.eval_on_selector!(page, "select", "select => select.options.length")
    select_promise = Runtime.Promise.async(fn -> Page.select_option!(page, "select", %{index: len}) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(select_promise)
    Page.eval_on_selector!(page, "select", @add_scarlet)
    items = Runtime.Promise.await(select_promise)
    assert items == ["scarlet"]
  end

  test "SO-028 should wait for multiple options to be present", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    Page.evaluate!(page, "() => window['makeMultiple']()")

    select_promise =
      Runtime.Promise.async(fn -> Page.select_option!(page, "select", ["green", "scarlet"]) end, shared: true)

    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(select_promise)
    Page.eval_on_selector!(page, "select", @add_scarlet)
    items = Runtime.Promise.await(select_promise)
    assert items == ["green", "scarlet"]
  end

  test "SO-029 input event.composed should be true and cross shadow dom boundary", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
    <body><script>
      const div = document.createElement('div');
      const shadowRoot = div.attachShadow({mode: 'open'});
      shadowRoot.innerHTML = `<select>
        <option value="black">Black</option>
        <option value="blue">Blue</option>
      </select>`;
      document.body.appendChild(div);
    </script></body>
    """)

    Locator.evaluate!(Page.locator(page, "body"), """
    select => {
      window.firedBodyEvents = [];
      for (const event of ['input', 'change']) {
        select.addEventListener(event, e => {
          window.firedBodyEvents.push(e.type + ':' + e.composed);
        }, false);
      }
    }
    """)

    Locator.evaluate!(Page.locator(page, "select"), """
    select => {
      window.firedEvents = [];
      for (const event of ['input', 'change']) {
        select.addEventListener(event, e => {
          window.firedEvents.push(e.type + ':' + e.composed);
        }, false);
      }
    }
    """)

    Page.select_option!(page, "select", "blue")
    assert Page.evaluate!(page, "() => window['firedEvents']") == ["input:true", "change:false"]
    assert Page.evaluate!(page, "() => window['firedBodyEvents']") == ["input:true"]
  end

  test "SO-030 should wait for select to be enabled", %{page: page} do
    Page.set_content!(page, """
    <select disabled>
      <option>one</option>
      <option>two</option>
    </select>

    <script>
    function hydrate() {
      const select = document.querySelector('select');
      select.removeAttribute('disabled');
      select.addEventListener('change', () => {
        window['result'] = select.value;
      });
    }
    </script>
    """)

    select_promise = Runtime.Promise.async(fn -> Locator.select_option!(Page.locator(page, "select"), "two") end)
    Process.sleep(1000)
    Page.evaluate!(page, "() => window.hydrate()")
    Runtime.Promise.await(select_promise)
    assert Page.evaluate!(page, "() => window['result']") == "two"
    Expect.to_have_value!(Page.locator(page, "select"), "two")
  end

  test "SO-031 should wait for option to be enabled", %{page: page} do
    Page.set_content!(page, """
    <select>
      <option>one</option>
      <option disabled id=myoption>two</option>
    </select>

    <script>
    function hydrate() {
      const option = document.querySelector('#myoption');
      option.removeAttribute('disabled');
      const select = document.querySelector('select');
      select.addEventListener('change', () => {
        window['result'] = select.value;
      });
    }
    </script>
    """)

    {:error, error} = Locator.select_option(Page.locator(page, "select"), "two", timeout: 1000)
    assert Exception.message(error) =~ "option being selected is not enabled"

    select_promise = Runtime.Promise.async(fn -> Locator.select_option!(Page.locator(page, "select"), "two") end)
    Process.sleep(1000)
    Page.evaluate!(page, "() => window.hydrate()")
    Runtime.Promise.await(select_promise)
    assert Page.evaluate!(page, "() => window['result']") == "two"
    Expect.to_have_value!(Page.locator(page, "select"), "two")
  end

  test "SO-032 should wait for optgroup to be enabled", %{page: page} do
    Page.set_content!(page, """
    <select>
      <option>one</option>
      <optgroup label="Group" disabled id=mygroup>
        <option>two</option>
      </optgroup>
    </select>

    <script>
    function hydrate() {
      const group = document.querySelector('#mygroup');
      group.removeAttribute('disabled');
      const select = document.querySelector('select');
      select.addEventListener('change', () => {
        window['result'] = select.value;
      });
    }
    </script>
    """)

    {:error, error} = Locator.select_option(Page.locator(page, "select"), "two", timeout: 1000)
    assert Exception.message(error) =~ "option being selected is not enabled"

    select_promise = Runtime.Promise.async(fn -> Locator.select_option!(Page.locator(page, "select"), "two") end)
    Process.sleep(1000)
    Page.evaluate!(page, "() => window.hydrate()")
    Runtime.Promise.await(select_promise)
    assert Page.evaluate!(page, "() => window['result']") == "two"
    Expect.to_have_value!(Page.locator(page, "select"), "two")
  end

  test "SO-033 should wait for select to be swapped", %{page: page} do
    Page.set_content!(page, """
    <select disabled>
      <option>one</option>
      <option>two</option>
    </select>

    <script>
    function hydrate() {
      const select = document.querySelector('select');
      select.remove();

      const newSelect = document.createElement('select');
      const option1 = document.createElement('option');
      option1.textContent = 'one';
      newSelect.appendChild(option1);
      const option2 = document.createElement('option');
      option2.textContent = 'two';
      newSelect.appendChild(option2);

      document.body.appendChild(newSelect);

      newSelect.addEventListener('change', () => {
        window['result'] = newSelect.value;
      });
    }
    </script>
    """)

    select_promise = Runtime.Promise.async(fn -> Locator.select_option!(Page.locator(page, "select"), "two") end)
    Process.sleep(1000)
    Page.evaluate!(page, "() => window.hydrate()")
    Runtime.Promise.await(select_promise)
    Expect.to_have_value!(Page.locator(page, "select"), "two")
    assert Page.evaluate!(page, "() => window['result']") == "two"
  end

  test "SO-034 should wait for select to become non-inert", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42967' }
    Page.set_content!(page, """
    <div inert id=container>
      <select>
        <option>one</option>
        <option>two</option>
      </select>
    </div>
    """)

    select_promise =
      Runtime.Promise.async(fn -> Locator.select_option!(Page.locator(page, "select"), "two") end, shared: true)

    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(select_promise)
    Expect.to_have_value!(Page.locator(page, "select"), "one")

    Page.evaluate!(page, "() => document.getElementById('container').removeAttribute('inert')")
    Runtime.Promise.await(select_promise)
    Expect.to_have_value!(Page.locator(page, "select"), "two")

    Page.evaluate!(page, "() => document.getElementById('container').setAttribute('inert', '')")
    {:error, error} = Locator.select_option(Page.locator(page, "select"), "one", timeout: 1000)
    assert Exception.message(error) =~ "Timeout 1000ms exceeded"
    assert Exception.message(error) =~ "element is inert"
  end
end
