defmodule PlaywrightEx.Examples.ExpectTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.TestServer

  @list "<ul><li>Text 1</li><li>Text 2</li><li>Text 3</li></ul>"

  example "LocatorAssertions",
    js: ~S"""
    import { test, expect } from '@playwright/test';

    test('status becomes submitted', async ({ page }) => {
      // ...
      await page.getByRole('button').click();
      await expect(page.locator('.status')).toHaveText('Submitted');
    });
    """,
    html: ~s{<button onclick="document.querySelector('.status').textContent = 'Submitted'">Submit</button>
    <div class="status">Pending</div>} do
    test "status becomes submitted", %{page: page} do
      # ...
      Page.get_by_role(page, :button) |> Locator.click!()
      Page.locator(page, ".status") |> Expect.to_have_text!("Submitted")
    end
  end

  example "LocatorAssertions.not",
    js: ~S"""
    await expect(locator).not.toContainText('error');
    """,
    html: "<div>All good</div>",
    given: [locator: Page.locator(page, "div")] do
    locator |> Expect.not_() |> Expect.to_contain_text!("error")
  end

  example "Expect.soft",
    js: ~S"""
    // Make a few checks that will not stop the test when failed...
    await expect.soft(page.getByTestId('status')).toHaveText('Success');
    await expect.soft(page.getByTestId('eta')).toHaveText('1 day');

    // ... and continue the test to check more things.
    await page.getByRole('link', { name: 'next page' }).click();
    await expect.soft(page.getByRole('heading', { name: 'Make another order' })).toBeVisible();
    """,
    html: ~s{<div data-testid="status">Success</div><div data-testid="eta">1 day</div>
    <a href="/next">next page</a><h1>Make another order</h1>} do
    # Make a few checks that will not stop the test when failed...
    Page.get_by_test_id(page, "status") |> Expect.soft() |> Expect.to_have_text!("Success")
    Page.get_by_test_id(page, "eta") |> Expect.soft() |> Expect.to_have_text!("1 day")

    # ... and continue the test to check more things.
    Page.get_by_role(page, :link, name: "next page") |> Locator.click!()
    Page.get_by_role(page, :heading, name: "Make another order") |> Expect.soft() |> Expect.to_be_visible!()
  end

  @api "requests https://api.example.com"

  example "Expect.toPass",
    js: ~S"""
    await expect(async () => {
      const response = await page.request.get('https://api.example.com');
      expect(response.status()).toBe(200);
    }).toPass();
    """,
    skip: @api do
    Expect.to_pass!(fn ->
      response = page |> Page.request() |> APIRequestContext.get!("https://api.example.com")
      assert APIResponse.status(response) == 200
    end)
  end

  example "Expect.toPass",
    js: ~S"""
    await expect(async () => {
      const response = await page.request.get('https://api.example.com');
      expect(response.status()).toBe(200);
    }).toPass({
      // Probe, wait 1s, probe, wait 2s, probe, wait 10s, probe, wait 10s, probe
      // ... Defaults to [100, 250, 500, 1000].
      intervals: [1_000, 2_000, 10_000],
      timeout: 60_000
    });
    """,
    skip: @api do
    Expect.to_pass!(
      fn ->
        response = page |> Page.request() |> APIRequestContext.get!("https://api.example.com")
        assert APIResponse.status(response) == 200
      end,
      # Probe, wait 1s, probe, wait 2s, probe, wait 10s, probe, wait 10s, probe
      # ... Defaults to [100, 250, 500, 1000].
      intervals: [1_000, 2_000, 10_000],
      timeout: 60_000
    )
  end

  example "Expect.poll",
    js: ~S"""
    await expect.poll(async () => {
      const response = await page.request.get('https://api.example.com');
      return response.status();
    }, {
      // Custom expect message for reporting, optional.
      message: 'make sure API eventually succeeds',
      // Poll for 10 seconds; defaults to 5 seconds. Pass 0 to disable timeout.
      timeout: 10000,
    }).toBe(200);
    """,
    skip: @api do
    Expect.poll!(
      fn ->
        response = page |> Page.request() |> APIRequestContext.get!("https://api.example.com")
        APIResponse.status(response)
      end,
      &assert(&1 == 200),
      # Custom expect message for reporting, optional.
      message: "make sure API eventually succeeds",
      # Poll for 10 seconds; defaults to 5 seconds. Pass 0 to disable timeout.
      timeout: 10_000
    )
  end

  example "Expect.poll",
    js: ~S"""
    await expect.poll(async () => {
      const response = await page.request.get('https://api.example.com');
      return response.status();
    }, {
      // Probe, wait 1s, probe, wait 2s, probe, wait 10s, probe, wait 10s, probe
      // ... Defaults to [100, 250, 500, 1000].
      intervals: [1_000, 2_000, 10_000],
      timeout: 60_000
    }).toBe(200);
    """,
    skip: @api do
    Expect.poll!(
      fn ->
        response = page |> Page.request() |> APIRequestContext.get!("https://api.example.com")
        APIResponse.status(response)
      end,
      &assert(&1 == 200),
      # Probe, wait 1s, probe, wait 2s, probe, wait 10s, probe, wait 10s, probe
      # ... Defaults to [100, 250, 500, 1000].
      intervals: [1_000, 2_000, 10_000],
      timeout: 60_000
    )
  end

  example "Expect.poll",
    js: ~S"""
    await expect.soft.poll(async () => {
      const response = await page.request.get('https://api.example.com');
      return response.status();
    }).toBe(200);
    """,
    skip: @api do
    fn ->
      response = page |> Page.request() |> APIRequestContext.get!("https://api.example.com")
      APIResponse.status(response)
    end
    |> Expect.soft()
    |> Expect.poll!(&assert(&1 == 200))
  end

  example "LocatorAssertions.toBeAttached",
    js: ~S"""
    await expect(page.getByText('Hidden text')).toBeAttached();
    """,
    html: "<span hidden>Hidden text</span>" do
    Page.get_by_text(page, "Hidden text") |> Expect.to_be_attached!()
  end

  example "LocatorAssertions.toBeChecked",
    js: ~S"""
    const locator = page.getByLabel('Subscribe to newsletter');
    await expect(locator).toBeChecked();
    """,
    html: ~s(<label><input type="checkbox" checked> Subscribe to newsletter</label>) do
    locator = Page.get_by_label(page, "Subscribe to newsletter")
    Expect.to_be_checked!(locator)
  end

  example "LocatorAssertions.toBeDisabled",
    js: ~S"""
    const locator = page.locator('button.submit');
    await expect(locator).toBeDisabled();
    """,
    html: ~s(<button class="submit" disabled>Submit</button>) do
    locator = Page.locator(page, "button.submit")
    Expect.to_be_disabled!(locator)
  end

  example "LocatorAssertions.toBeEditable",
    js: ~S"""
    const locator = page.getByRole('textbox');
    await expect(locator).toBeEditable();
    """,
    html: "<input>" do
    locator = Page.get_by_role(page, :textbox)
    Expect.to_be_editable!(locator)
  end

  example "LocatorAssertions.toBeEmpty",
    js: ~S"""
    const locator = page.locator('div.warning');
    await expect(locator).toBeEmpty();
    """,
    html: ~s(<div class="warning"></div>) do
    locator = Page.locator(page, "div.warning")
    Expect.to_be_empty!(locator)
  end

  example "LocatorAssertions.toBeEnabled",
    js: ~S"""
    const locator = page.locator('button.submit');
    await expect(locator).toBeEnabled();
    """,
    html: ~s(<button class="submit">Submit</button>) do
    locator = Page.locator(page, "button.submit")
    Expect.to_be_enabled!(locator)
  end

  example "LocatorAssertions.toBeFocused",
    js: ~S"""
    const locator = page.getByRole('textbox');
    await expect(locator).toBeFocused();
    """,
    html: ~s{<input><script>document.querySelector('input').focus()</script>} do
    locator = Page.get_by_role(page, :textbox)
    Expect.to_be_focused!(locator)
  end

  example "LocatorAssertions.toBeHidden",
    js: ~S"""
    const locator = page.locator('.my-element');
    await expect(locator).toBeHidden();
    """,
    html: ~s(<div class="my-element" hidden>Hidden</div>) do
    locator = Page.locator(page, ".my-element")
    Expect.to_be_hidden!(locator)
  end

  # The button is in the viewport, fully outside it from 1 s, back from 3 s: each assertion holds.
  example "LocatorAssertions.toBeInViewport",
    js: ~S"""
    const locator = page.getByRole('button');
    // Make sure at least some part of element intersects viewport.
    await expect(locator).toBeInViewport();
    // Make sure element is fully outside of viewport.
    await expect(locator).not.toBeInViewport();
    // Make sure that at least half of the element intersects viewport.
    await expect(locator).toBeInViewport({ ratio: 0.5 });
    """,
    html: ~s{<button style="position: absolute; top: 0">Go</button>
    <script>
      const button = document.querySelector('button');
      setTimeout(() => button.style.top = '2000px', 1000);
      setTimeout(() => button.style.top = '0', 3000);
    </script>} do
    locator = Page.get_by_role(page, :button)
    # Make sure at least some part of element intersects viewport.
    Expect.to_be_in_viewport!(locator)
    # Make sure element is fully outside of viewport.
    Expect.not_to_be_in_viewport!(locator)
    # Make sure that at least half of the element intersects viewport.
    Expect.to_be_in_viewport!(locator, ratio: 0.5)
  end

  example "LocatorAssertions.toBeVisible",
    js: ~S"""
    // A specific element is visible.
    await expect(page.getByText('Welcome')).toBeVisible();

    // At least one item in the list is visible.
    await expect(page.getByTestId('todo-item').first()).toBeVisible();

    // At least one of the two elements is visible, possibly both.
    await expect(
        page.getByRole('button', { name: 'Sign in' })
            .or(page.getByRole('button', { name: 'Sign up' }))
            .first()
    ).toBeVisible();
    """,
    html: """
    <p>Welcome</p>
    <ul><li data-testid="todo-item">Buy milk</li><li data-testid="todo-item">Walk the dog</li></ul>
    <button>Sign in</button>
    """ do
    # A specific element is visible.
    Page.get_by_text(page, "Welcome") |> Expect.to_be_visible!()

    # At least one item in the list is visible.
    Page.get_by_test_id(page, "todo-item") |> Locator.first() |> Expect.to_be_visible!()

    # At least one of the two elements is visible, possibly both.
    Page.get_by_role(page, :button, name: "Sign in")
    |> Locator.or_(Page.get_by_role(page, :button, name: "Sign up"))
    |> Locator.first()
    |> Expect.to_be_visible!()
  end

  example "LocatorAssertions.toContainClass",
    js: ~S"""
    const locator = page.locator('#component');
    await expect(locator).toContainClass('middle selected row');
    await expect(locator).toContainClass('selected');
    await expect(locator).toContainClass('row middle');
    """,
    html: ~s(<div id="component" class="middle selected row"></div>) do
    locator = Page.locator(page, "#component")
    Expect.to_contain_class!(locator, "middle selected row")
    Expect.to_contain_class!(locator, "selected")
    Expect.to_contain_class!(locator, "row middle")
  end

  example "LocatorAssertions.toContainClass",
    js: ~S"""
    const locator = page.locator('.list > .component');
    await expect(locator).toContainClass(['inactive', 'active', 'inactive']);
    """,
    html: """
    <div class="list">
      <div class="component inactive"></div>
      <div class="component active"></div>
      <div class="component inactive"></div>
    </div>
    """ do
    locator = Page.locator(page, ".list > .component")
    Expect.to_contain_class!(locator, ["inactive", "active", "inactive"])
  end

  example "LocatorAssertions.toContainText",
    js: ~S"""
    const locator = page.locator('.title');
    await expect(locator).toContainText('substring');
    await expect(locator).toContainText(/\d messages/);
    """,
    html: ~s(<div class="title">A substring: 3 messages</div>) do
    locator = Page.locator(page, ".title")
    Expect.to_contain_text!(locator, "substring")
    Expect.to_contain_text!(locator, ~r/\d messages/)
  end

  # Each failing assertion takes the expect timeout (10 s in the tests). Upstream marks the last
  # one failing, but the driver passes it (one element, whose text contains "Text 3").
  @tag timeout: 60_000
  example "LocatorAssertions.toContainText",
    js: ~S"""
    // ✓ Contains the right items in the right order
    await expect(page.locator('ul > li')).toContainText(['Text 1', 'Text 3']);

    // ✖ Wrong order
    await expect(page.locator('ul > li')).toContainText(['Text 3', 'Text 2']);

    // ✖ No item contains this text
    await expect(page.locator('ul > li')).toContainText(['Some 33']);

    // ✖ Locator points to the outer list element, not to the list items
    await expect(page.locator('ul')).toContainText(['Text 3']);
    """,
    html: @list do
    # ✓ Contains the right items in the right order
    Page.locator(page, "ul > li") |> Expect.to_contain_text!(["Text 1", "Text 3"])

    # ✖ Wrong order
    {:error, _} = Page.locator(page, "ul > li") |> Expect.to_contain_text(["Text 3", "Text 2"])

    # ✖ No item contains this text
    {:error, _} = Page.locator(page, "ul > li") |> Expect.to_contain_text(["Some 33"])

    # ✖ Locator points to the outer list element, not to the list items
    # (in fact it passes: the list's text contains "Text 3")
    :ok = Page.locator(page, "ul") |> Expect.to_contain_text(["Text 3"])
  end

  example "LocatorAssertions.toHaveAccessibleDescription",
    js: ~S"""
    const locator = page.getByTestId('save-button');
    await expect(locator).toHaveAccessibleDescription('Save results to disk');
    """,
    html:
      ~s(<button data-testid="save-button" aria-describedby="hint">Save</button><p id="hint">Save results to disk</p>) do
    locator = Page.get_by_test_id(page, "save-button")
    Expect.to_have_accessible_description!(locator, "Save results to disk")
  end

  example "LocatorAssertions.toHaveAccessibleErrorMessage",
    js: ~S"""
    const locator = page.getByTestId('username-input');
    await expect(locator).toHaveAccessibleErrorMessage('Username is required.');
    """,
    html: """
    <input data-testid="username-input" aria-invalid="true" aria-errormessage="error">
    <p id="error">Username is required.</p>
    """ do
    locator = Page.get_by_test_id(page, "username-input")
    Expect.to_have_accessible_error_message!(locator, "Username is required.")
  end

  example "LocatorAssertions.toHaveAccessibleName",
    js: ~S"""
    const locator = page.getByTestId('save-button');
    await expect(locator).toHaveAccessibleName('Save to disk');
    """,
    html: ~s(<button data-testid="save-button">Save to disk</button>) do
    locator = Page.get_by_test_id(page, "save-button")
    Expect.to_have_accessible_name!(locator, "Save to disk")
  end

  example "LocatorAssertions.toHaveAttribute",
    js: ~S"""
    const locator = page.locator('input');
    await expect(locator).toHaveAttribute('type', 'text');
    """,
    html: ~s(<input type="text">) do
    locator = Page.locator(page, "input")
    Expect.to_have_attribute!(locator, "type", "text")
  end

  example "LocatorAssertions.toHaveAttribute (existence)",
    js: ~S"""
    const locator = page.locator('input');
    // Assert attribute existence.
    await expect(locator).toHaveAttribute('disabled');
    await expect(locator).not.toHaveAttribute('open');
    """,
    html: ~s(<input disabled>) do
    locator = Page.locator(page, "input")
    # Assert attribute existence.
    Expect.to_have_attribute!(locator, "disabled")
    Expect.not_to_have_attribute!(locator, "open")
  end

  example "LocatorAssertions.toHaveClass",
    js: ~S"""
    const locator = page.locator('#component');
    await expect(locator).toHaveClass('middle selected row');
    await expect(locator).toHaveClass(/(^|\s)selected(\s|$)/);
    """,
    html: ~s(<div id="component" class="middle selected row"></div>) do
    locator = Page.locator(page, "#component")
    Expect.to_have_class!(locator, "middle selected row")
    Expect.to_have_class!(locator, ~r/(^|\s)selected(\s|$)/)
  end

  example "LocatorAssertions.toHaveClass",
    js: ~S"""
    const locator = page.locator('.list > .component');
    await expect(locator).toHaveClass(['component', 'component selected', 'component']);
    """,
    html: """
    <div class="list">
      <div class="component"></div>
      <div class="component selected"></div>
      <div class="component"></div>
    </div>
    """ do
    locator = Page.locator(page, ".list > .component")
    Expect.to_have_class!(locator, ["component", "component selected", "component"])
  end

  # Upstream's selector is `list > .component` (a `<list>` element), likely meant as `.list`.
  example "LocatorAssertions.toHaveCount",
    js: ~S"""
    const list = page.locator('list > .component');
    await expect(list).toHaveCount(3);
    """,
    html: """
    <list>
      <div class="component"></div>
      <div class="component"></div>
      <div class="component"></div>
    </list>
    """ do
    list = Page.locator(page, "list > .component")
    Expect.to_have_count!(list, 3)
  end

  example "LocatorAssertions.toHaveCSS",
    js: ~S"""
    const locator = page.getByRole('button');
    await expect(locator).toHaveCSS('display', 'flex');
    """,
    html: ~s(<button style="display: flex">Go</button>) do
    locator = Page.get_by_role(page, :button)
    Expect.to_have_css!(locator, "display", "flex")
  end

  example "LocatorAssertions.toHaveId",
    js: ~S"""
    const locator = page.getByRole('textbox');
    await expect(locator).toHaveId('lastname');
    """,
    html: ~s(<input id="lastname">) do
    locator = Page.get_by_role(page, :textbox)
    Expect.to_have_id!(locator, "lastname")
  end

  example "LocatorAssertions.toHaveJSProperty",
    js: ~S"""
    const locator = page.locator('.component');
    await expect(locator).toHaveJSProperty('loaded', true);
    """,
    html: ~s{<div class="component"></div><script>document.querySelector(".component").loaded = true</script>} do
    locator = Page.locator(page, ".component")
    Expect.to_have_js_property!(locator, "loaded", true)
  end

  example "LocatorAssertions.toHaveRole",
    js: ~S"""
    const locator = page.getByTestId('save-button');
    await expect(locator).toHaveRole('button');
    """,
    html: ~s(<button data-testid="save-button">Save</button>) do
    locator = Page.get_by_test_id(page, "save-button")
    Expect.to_have_role!(locator, :button)
  end

  example "LocatorAssertions.toHaveText",
    js: ~S"""
    const locator = page.locator('.title');
    await expect(locator).toHaveText(/Welcome, Test User/);
    await expect(locator).toHaveText(/Welcome, .*/);
    """,
    html: ~s(<h1 class="title">Welcome, Test User</h1>) do
    locator = Page.locator(page, ".title")
    Expect.to_have_text!(locator, ~r/Welcome, Test User/)
    Expect.to_have_text!(locator, ~r/Welcome, .*/)
  end

  # Each failing assertion takes the expect timeout (10 s in the tests).
  @tag timeout: 60_000
  example "LocatorAssertions.toHaveText",
    js: ~S"""
    // ✓ Has the right items in the right order
    await expect(page.locator('ul > li')).toHaveText(['Text 1', 'Text 2', 'Text 3']);

    // ✖ Wrong order
    await expect(page.locator('ul > li')).toHaveText(['Text 3', 'Text 2', 'Text 1']);

    // ✖ Last item does not match
    await expect(page.locator('ul > li')).toHaveText(['Text 1', 'Text 2', 'Text']);

    // ✖ Locator points to the outer list element, not to the list items
    await expect(page.locator('ul')).toHaveText(['Text 1', 'Text 2', 'Text 3']);
    """,
    html: @list do
    # ✓ Has the right items in the right order
    Page.locator(page, "ul > li") |> Expect.to_have_text!(["Text 1", "Text 2", "Text 3"])

    # ✖ Wrong order
    {:error, _} = Page.locator(page, "ul > li") |> Expect.to_have_text(["Text 3", "Text 2", "Text 1"])

    # ✖ Last item does not match
    {:error, _} = Page.locator(page, "ul > li") |> Expect.to_have_text(["Text 1", "Text 2", "Text"])

    # ✖ Locator points to the outer list element, not to the list items
    {:error, _} = Page.locator(page, "ul") |> Expect.to_have_text(["Text 1", "Text 2", "Text 3"])
  end

  example "LocatorAssertions.toHaveValue",
    js: ~S"""
    const locator = page.locator('input[type=number]');
    await expect(locator).toHaveValue(/[0-9]/);
    """,
    html: ~s(<input type="number" value="42">) do
    locator = Page.locator(page, "input[type=number]")
    Expect.to_have_value!(locator, ~r/[0-9]/)
  end

  example "LocatorAssertions.toHaveValues",
    js: ~S"""
    const locator = page.locator('id=favorite-colors');
    await locator.selectOption(['R', 'G']);
    await expect(locator).toHaveValues([/R/, /G/]);
    """,
    html: """
    <select id="favorite-colors" multiple>
      <option value="R">Red</option>
      <option value="G">Green</option>
      <option value="B">Blue</option>
    </select>
    """ do
    locator = Page.locator(page, "id=favorite-colors")
    Locator.select_option!(locator, ["R", "G"])
    Expect.to_have_values!(locator, [~r/R/, ~r/G/])
  end

  example "LocatorAssertions.toMatchAriaSnapshot",
    js: ~S"""
    await page.goto('https://demo.playwright.dev/todomvc/');
    await expect(page.locator('body')).toMatchAriaSnapshot(`
      - heading "todos"
      - textbox "What needs to be done?"
    `);
    """,
    html: ~s(<h1>todos</h1><input placeholder="What needs to be done?">) do
    Page.goto!(page, "https://demo.playwright.dev/todomvc/")

    Page.locator(page, "body")
    |> Expect.to_match_aria_snapshot!("""
    - heading "todos"
    - textbox "What needs to be done?"
    """)
  end

  example "APIResponseAssertions.toBeOK",
    js: ~S"""
    await expect(response).toBeOK();
    """,
    given: [
      server: TestServer.create(nil),
      _route: TestServer.set_route(server, "/ok", &Plug.Conn.send_resp(&1, 200, "OK")),
      response: page |> Page.request() |> APIRequestContext.get!(server.prefix <> "/ok")
    ] do
    Expect.to_be_ok!(response)
  end

  example "PageAssertions.toHaveTitle",
    js: ~S"""
    await expect(page).toHaveTitle(/.*checkout/);
    """,
    html: "<title>Shop checkout</title>" do
    Expect.to_have_title!(page, ~r/.*checkout/)
  end

  # The page gets the query string after 1 s, for the predicate.
  example "PageAssertions.toHaveURL",
    js: ~S"""
    // Check for the page URL to be 'https://playwright.dev/docs/intro' (including query string)
    await expect(page).toHaveURL('https://playwright.dev/docs/intro');

    // Check for the page URL to contain 'doc', followed by an optional 's', followed by '/'
    await expect(page).toHaveURL(/docs?\//);

    // Check for the page URL to match the URL pattern
    await expect(page).toHaveURL(new URLPattern({ pathname: '/docs/*' }));

    // Check for the predicate to be satisfied
    // For example: verify query strings
    await expect(page).toHaveURL(url => {
      const params = url.searchParams;
      return params.has('search') && params.has('options') && params.get('id') === '5';
    });
    """,
    html: ~s{<script>setTimeout(() => history.replaceState(null, "", "?search=a&options=b&id=5"), 1000)</script>},
    given: [_navigated: Page.goto!(page, "https://playwright.dev/docs/intro")] do
    # Check for the page URL to be 'https://playwright.dev/docs/intro' (including query string)
    Expect.to_have_url!(page, "https://playwright.dev/docs/intro")

    # Check for the page URL to contain 'doc', followed by an optional 's', followed by '/'
    Expect.to_have_url!(page, ~r/docs?\//)

    # Check for the page URL to match the URL pattern (Elixir has no URLPattern: a predicate)
    Expect.to_have_url!(page, &String.starts_with?(URI.parse(&1).path, "/docs/"))

    # Check for the predicate to be satisfied
    # For example: verify query strings
    Expect.to_have_url!(page, fn url ->
      params = URI.decode_query(URI.parse(url).query || "")
      Map.has_key?(params, "search") and Map.has_key?(params, "options") and params["id"] == "5"
    end)
  end
end
