defmodule PlaywrightEx.Examples.LocatorTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  @dropzone ~s{<div id="dropzone" style="width: 100px; height: 100px" ondragover="event.preventDefault()"></div>}

  example "Locator.all",
    js: ~S"""
    for (const li of await page.getByRole('listitem').all())
      await li.click();
    """,
    html: "<ul><li>one</li><li>two</li></ul>" do
    for li <- Page.get_by_role(page, :listitem) |> Locator.all!() do
      Locator.click!(li)
    end
  end

  example "Locator.boundingBox",
    js: ~S"""
    const box = await page.getByRole('button').boundingBox();
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    """,
    html: "<button>Go</button>" do
    box = Page.get_by_role(page, :button) |> Locator.bounding_box!()
    Mouse.click!(Page.mouse(page), box.x + box.width / 2, box.y + box.height / 2)
  end

  example "Locator.click",
    js: ~S"""
    await page.locator('canvas').click({
      button: 'right',
      modifiers: ['Shift'],
      position: { x: 23, y: 32 },
    });
    """,
    html: "<canvas></canvas>" do
    Page.locator(page, "canvas")
    |> Locator.click!(button: :right, modifiers: [:shift], position: %{x: 23, y: 32})
  end

  example "Locator.evaluate",
    js: ~S"""
    const result = await page.getByTestId('myId').evaluate((element, [x, y]) => {
      return element.textContent + ' ' + x * y;
    }, [7, 8]);
    console.log(result); // prints "myId text 56"
    """,
    html: ~s(<div data-testid="myId">myId text</div>) do
    result =
      Page.get_by_test_id(page, "myId")
      |> Locator.evaluate!("(element, [x, y]) => element.textContent + ' ' + x * y", [7, 8])

    # prints "myId text 56"
    IO.puts(result)
  end

  example "Locator.allInnerTexts",
    js: ~S"""
    const texts = await page.getByRole('link').allInnerTexts();
    """,
    html: ~s(<a href="/a">one</a><a href="/b">two</a>) do
    texts = Page.get_by_role(page, :link) |> Locator.all_inner_texts!()
  end

  example "Locator.allTextContents",
    js: ~S"""
    const texts = await page.getByRole('link').allTextContents();
    """,
    html: ~s(<a href="/a">one</a><a href="/b">two</a>) do
    texts = Page.get_by_role(page, :link) |> Locator.all_text_contents!()
  end

  example "Locator.and",
    js: ~S"""
    const button = page.getByRole('button').and(page.getByTitle('Subscribe'));
    """ do
    button = Page.get_by_role(page, :button) |> Locator.and_(Page.get_by_title(page, "Subscribe"))
  end

  example "Locator.ariaSnapshot",
    js: ~S"""
    await page.getByRole('link').ariaSnapshot();
    """,
    html: ~s(<a href="/a">one</a>) do
    Page.get_by_role(page, :link) |> Locator.aria_snapshot!()
  end

  example "Locator.ariaSnapshotJSON",
    js: ~S"""
    await page.getByRole('list').ariaSnapshotJSON();
    """,
    html: "<ul><li>one</li><li>two</li></ul>" do
    Page.get_by_role(page, :list) |> Locator.aria_snapshot_json!()
  end

  example "Locator.check",
    js: ~S"""
    await page.getByRole('checkbox').check();
    """,
    html: ~s(<input type="checkbox">) do
    Page.get_by_role(page, :checkbox) |> Locator.check!()
  end

  example "Locator.clear",
    js: ~S"""
    await page.getByRole('textbox').clear();
    """,
    html: ~s(<input value="text">) do
    Page.get_by_role(page, :textbox) |> Locator.clear!()
  end

  example "Locator.click",
    js: ~S"""
    await page.getByRole('button').click();
    """,
    html: "<button>Go</button>" do
    Page.get_by_role(page, :button) |> Locator.click!()
  end

  example "Locator.count",
    js: ~S"""
    const count = await page.getByRole('listitem').count();
    """,
    html: "<ul><li>one</li><li>two</li></ul>" do
    count = Page.get_by_role(page, :listitem) |> Locator.count!()
  end

  example "Locator.fill",
    js: ~S"""
    await page.getByRole('textbox').fill('example value');
    """,
    html: "<input>" do
    Page.get_by_role(page, :textbox) |> Locator.fill!("example value")
  end

  example "Locator.getByAltText",
    js: ~S"""
    await page.getByAltText('Playwright logo').click();
    """,
    html: ~s(<img alt="Playwright logo" width="40" height="40">) do
    Page.get_by_alt_text(page, "Playwright logo") |> Locator.click!()
  end

  example "Locator.getByLabel",
    js: ~S"""
    await page.getByLabel('Username').fill('john');
    await page.getByLabel('Password').fill('secret');
    """,
    html: ~s(<label>Username <input></label><label>Password <input type="password"></label>) do
    Page.get_by_label(page, "Username") |> Locator.fill!("john")
    Page.get_by_label(page, "Password") |> Locator.fill!("secret")
  end

  example "Locator.getByPlaceholder",
    js: ~S"""
    await page
        .getByPlaceholder('name@example.com')
        .fill('playwright@microsoft.com');
    """,
    html: ~s(<input type="email" placeholder="name@example.com">) do
    Page.get_by_placeholder(page, "name@example.com") |> Locator.fill!("playwright@microsoft.com")
  end

  example "Locator.getByRole",
    js: ~S"""
    await expect(page.getByRole('heading', { name: 'Sign up' })).toBeVisible();

    await page.getByRole('checkbox', { name: 'Subscribe' }).check();

    await page.getByRole('button', { name: /submit/i }).click();
    """,
    html: """
    <h3>Sign up</h3>
    <label><input type="checkbox"> Subscribe</label>
    <button>Submit</button>
    """ do
    Page.get_by_role(page, :heading, name: "Sign up") |> Expect.to_be_visible!()

    Page.get_by_role(page, :checkbox, name: "Subscribe") |> Locator.check!()

    Page.get_by_role(page, :button, name: ~r/submit/i) |> Locator.click!()
  end

  example "Locator.getByTestId",
    js: ~S"""
    await page.getByTestId('directions').click();
    """,
    html: ~s(<button data-testid="directions">Itinéraire</button>) do
    Page.get_by_test_id(page, "directions") |> Locator.click!()
  end

  example "Locator.hover",
    js: ~S"""
    await page.getByRole('link').hover();
    """,
    html: ~s(<a href="/a">one</a>) do
    Page.get_by_role(page, :link) |> Locator.hover!()
  end

  example "Locator.inputValue",
    js: ~S"""
    const value = await page.getByRole('textbox').inputValue();
    """,
    html: ~s(<input value="text">) do
    value = Page.get_by_role(page, :textbox) |> Locator.input_value!()
  end

  example "Locator.isChecked",
    js: ~S"""
    const checked = await page.getByRole('checkbox').isChecked();
    """,
    html: ~s(<input type="checkbox" checked>) do
    checked = Page.get_by_role(page, :checkbox) |> Locator.is_checked!()
  end

  example "Locator.isDisabled",
    js: ~S"""
    const disabled = await page.getByRole('button').isDisabled();
    """,
    html: "<button disabled>Go</button>" do
    disabled = Page.get_by_role(page, :button) |> Locator.is_disabled!()
  end

  example "Locator.isEditable",
    js: ~S"""
    const editable = await page.getByRole('textbox').isEditable();
    """,
    html: "<input>" do
    editable = Page.get_by_role(page, :textbox) |> Locator.is_editable!()
  end

  example "Locator.isEnabled",
    js: ~S"""
    const enabled = await page.getByRole('button').isEnabled();
    """,
    html: "<button>Go</button>" do
    enabled = Page.get_by_role(page, :button) |> Locator.is_enabled!()
  end

  example "Locator.isHidden",
    js: ~S"""
    const hidden = await page.getByRole('button').isHidden();
    """,
    html: "<button>Go</button>" do
    hidden = Page.get_by_role(page, :button) |> Locator.is_hidden!()
  end

  example "Locator.isVisible",
    js: ~S"""
    const visible = await page.getByRole('button').isVisible();
    """,
    html: "<button>Go</button>" do
    visible = Page.get_by_role(page, :button) |> Locator.is_visible!()
  end

  example "Locator.last",
    js: ~S"""
    const banana = await page.getByRole('listitem').last();
    """ do
    banana = Page.get_by_role(page, :listitem) |> Locator.last()
  end

  example "Locator.nth",
    js: ~S"""
    const banana = await page.getByRole('listitem').nth(2);
    """ do
    banana = Page.get_by_role(page, :listitem) |> Locator.nth(2)
  end

  example "Locator.press",
    js: ~S"""
    await page.getByRole('textbox').press('Backspace');
    """,
    html: ~s(<input value="text">) do
    Page.get_by_role(page, :textbox) |> Locator.press!("Backspace")
  end

  example "Locator.screenshot",
    js: ~S"""
    await page.getByRole('link').screenshot();
    """,
    html: ~s(<a href="/a">one</a>) do
    Page.get_by_role(page, :link) |> Locator.screenshot!()
  end

  example "Locator.setChecked",
    js: ~S"""
    await page.getByRole('checkbox').setChecked(true);
    """,
    html: ~s(<input type="checkbox">) do
    Page.get_by_role(page, :checkbox) |> Locator.set_checked!(true)
  end

  example "Locator.uncheck",
    js: ~S"""
    await page.getByRole('checkbox').uncheck();
    """,
    html: ~s(<input type="checkbox" checked>) do
    Page.get_by_role(page, :checkbox) |> Locator.uncheck!()
  end

  example "Locator.visible",
    js: ~S"""
    await page.locator('button').visible().click();
    """,
    html: ~s(<button hidden>Hidden</button><button>Go</button>) do
    Page.locator(page, "button") |> Locator.visible() |> Locator.click!()
  end

  example "Locator.describe",
    js: ~S"""
    const button = page.getByTestId('btn-sub').describe('Subscribe button');
    await button.click();
    """,
    html: ~s(<button data-testid="btn-sub">Subscribe</button>) do
    button = Page.get_by_test_id(page, "btn-sub") |> Locator.describe("Subscribe button")
    Locator.click!(button)
  end

  example "Locator.description",
    js: ~S"""
    const button = page.getByRole('button').describe('Subscribe button');
    console.log(button.description()); // "Subscribe button"

    const input = page.getByRole('textbox');
    console.log(input.description()); // null
    """ do
    button = Page.get_by_role(page, :button) |> Locator.describe("Subscribe button")
    Locator.description(button)
    # => "Subscribe button"

    input = Page.get_by_role(page, :textbox)
    Locator.description(input)
    # => nil
  end

  example "Locator.dispatchEvent",
    js: ~S"""
    await locator.dispatchEvent('click');
    """,
    html: "<button>Go</button>",
    given: [locator: Page.locator(page, "button")] do
    Locator.dispatch_event!(locator, "click")
  end

  example "Locator.dispatchEvent",
    js: ~S"""
    const dataTransfer = await page.evaluateHandle(() => new DataTransfer());
    await locator.dispatchEvent('dragstart', { dataTransfer });
    """,
    html: ~s(<div draggable="true">Drag me</div>),
    given: [locator: Page.locator(page, "div")] do
    data_transfer = Page.evaluate_handle!(page, "() => new DataTransfer()")
    Locator.dispatch_event!(locator, "dragstart", %{dataTransfer: data_transfer})
  end

  example "Locator.dragTo",
    js: ~S"""
    const source = page.locator('#source');
    const target = page.locator('#target');

    await source.dragTo(target);
    // or specify exact positions relative to the top-left corners of the elements:
    await source.dragTo(target, {
      sourcePosition: { x: 34, y: 7 },
      targetPosition: { x: 10, y: 20 },
    });
    """,
    html: """
    <div id="source" draggable="true" style="width: 100px; height: 50px">source</div>
    <div id="target" style="width: 100px; height: 50px">target</div>
    """ do
    source = Page.locator(page, "#source")
    target = Page.locator(page, "#target")

    Locator.drag_to!(source, target)
    # or specify exact positions relative to the top-left corners of the elements:
    Locator.drag_to!(source, target, source_position: %{x: 34, y: 7}, target_position: %{x: 10, y: 20})
  end

  example "Locator.drop",
    js: ~S"""
    await page.locator('#dropzone').drop({
      files: { name: 'note.txt', mimeType: 'text/plain', buffer: Buffer.from('hello') },
    });
    """,
    html: @dropzone do
    Page.locator(page, "#dropzone")
    |> Locator.drop!(%{files: %{name: "note.txt", mimeType: "text/plain", buffer: "hello"}})
  end

  example "Locator.drop",
    js: ~S"""
    await page.locator('#dropzone').drop({
      data: {
        'text/plain': 'hello world',
        'text/uri-list': 'https://example.com',
      },
    });
    """,
    html: @dropzone do
    Page.locator(page, "#dropzone")
    |> Locator.drop!(%{data: %{"text/plain" => "hello world", "text/uri-list" => "https://example.com"}})
  end

  example "Locator.contentFrame",
    js: ~S"""
    const locator = page.locator('iframe[name="embedded"]');
    // ...
    const frameLocator = locator.contentFrame();
    await frameLocator.getByRole('button').click();
    """,
    html: ~s(<iframe name="embedded" srcdoc="<button>Go</button>"></iframe>) do
    locator = Page.locator(page, ~s(iframe[name="embedded"]))
    # ...
    frame_locator = Locator.content_frame(locator)
    FrameLocator.get_by_role(frame_locator, :button) |> Locator.click!()
  end

  example "Locator.evaluateAll",
    js: ~S"""
    const locator = page.locator('div');
    const moreThanTen = await locator.evaluateAll((divs, min) => divs.length > min, 10);
    """,
    html: "<div>one</div><div>two</div>" do
    locator = Page.locator(page, "div")
    more_than_ten = Locator.evaluate_all!(locator, "(divs, min) => divs.length > min", 10)
  end

  example "Locator.filter",
    js: ~S"""
    const rowLocator = page.locator('tr');
    // ...
    await rowLocator
        .filter({ hasText: 'text in column 1' })
        .filter({ has: page.getByRole('button', { name: 'column 2 button' }) })
        .screenshot();
    """,
    html: """
    <table>
      <tr><td>text in column 1</td><td><button>column 2 button</button></td></tr>
      <tr><td>text in column 1</td><td><button>other button</button></td></tr>
    </table>
    """ do
    row_locator = Page.locator(page, "tr")
    # ...
    row_locator
    |> Locator.filter(has_text: "text in column 1")
    |> Locator.filter(has: Page.get_by_role(page, :button, name: "column 2 button"))
    |> Locator.screenshot!()
  end

  example "Locator.frameLocator",
    js: ~S"""
    const locator = page.frameLocator('iframe').getByText('Submit');
    await locator.click();
    """,
    html: ~s(<iframe srcdoc="<button>Submit</button>"></iframe>) do
    locator = Page.frame_locator(page, "iframe") |> FrameLocator.get_by_text("Submit")
    Locator.click!(locator)
  end

  example "Locator.getByTestId",
    js: ~S"""
    // Set custom test id attribute from @playwright/test config:
    import { defineConfig } from '@playwright/test';

    export default defineConfig({
      use: {
        testIdAttribute: 'data-pw'
      },
    });
    """,
    skip: "sets the test id attribute of every connection in the VM" do
    # Set a custom test id attribute:
    Playwright.selectors(playwright) |> Selectors.set_test_id_attribute("data-pw")
  end

  example "Locator.getByText",
    js: ~S"""
    // Matches <span>
    page.getByText('world');

    // Matches first <div>
    page.getByText('Hello world');

    // Matches second <div>
    page.getByText('Hello', { exact: true });

    // Matches both <div>s
    page.getByText(/Hello/);

    // Matches second <div>
    page.getByText(/^hello$/i);
    """,
    html: "<div>Hello <span>world</span></div><div>Hello</div>" do
    # Matches <span>
    Page.get_by_text(page, "world")

    # Matches first <div>
    Page.get_by_text(page, "Hello world")

    # Matches second <div>
    Page.get_by_text(page, "Hello", exact: true)

    # Matches both <div>s
    Page.get_by_text(page, ~r/Hello/)

    # Matches second <div>
    Page.get_by_text(page, ~r/^hello$/i)
  end

  example "Locator.getByTitle",
    js: ~S"""
    await expect(page.getByTitle('Issues count')).toHaveText('25 issues');
    """,
    html: ~s(<span title="Issues count">25 issues</span>) do
    Page.get_by_title(page, "Issues count") |> Expect.to_have_text!("25 issues")
  end

  example "Locator.highlight",
    js: ~S"""
    await locator.highlight({ style: 'outline: 2px dashed red' });
    await locator.highlight({ style: { color: 'red' } });
    """,
    html: "<button>Go</button>",
    given: [locator: Page.locator(page, "button")] do
    Locator.highlight!(locator, style: "outline: 2px dashed red")
    Locator.highlight!(locator, style: %{"color" => "red"})
  end

  example "Locator.normalize",
    js: ~S"""
    const normalized = await page.getByRef('e2').normalize();
    console.log(normalized.toString());
    // getByRole('button', { name: 'Submit' })
    """,
    html: "<button>Submit</button>",
    given: [_snapshot: Page.aria_snapshot!(page, mode: :ai)] do
    normalized = Page.get_by_ref(page, "e2") |> Locator.normalize!()
    # prints Page.get_by_role(page, :button, name: "Submit")
    IO.puts(Locator.to_string(normalized))
  end

  example "Locator.or",
    js: ~S"""
    const newEmail = page.getByRole('button', { name: 'New' });
    const dialog = page.getByText('Confirm security settings');
    await expect(newEmail.or(dialog).first()).toBeVisible();
    if (await dialog.isVisible())
      await page.getByRole('button', { name: 'Dismiss' }).click();
    await newEmail.click();
    """,
    html: """
    <button>New</button>
    <div id="dialog">Confirm security settings <button onclick="dialog.remove()">Dismiss</button></div>
    """ do
    new_email = Page.get_by_role(page, :button, name: "New")
    dialog = Page.get_by_text(page, "Confirm security settings")
    new_email |> Locator.or_(dialog) |> Locator.first() |> Expect.to_be_visible!()

    if Locator.is_visible!(dialog) do
      Page.get_by_role(page, :button, name: "Dismiss") |> Locator.click!()
    end

    Locator.click!(new_email)
  end

  example "Locator.pressSequentially",
    js: ~S"""
    await locator.pressSequentially('Hello'); // Types instantly
    await locator.pressSequentially('World', { delay: 100 }); // Types slower, like a user
    """,
    html: "<input>",
    given: [locator: Page.locator(page, "input")] do
    # Types instantly
    Locator.press_sequentially!(locator, "Hello")
    # Types slower, like a user
    Locator.press_sequentially!(locator, "World", delay: 100)
  end

  example "Locator.pressSequentially",
    js: ~S"""
    const locator = page.getByLabel('Password');
    await locator.pressSequentially('my password');
    await locator.press('Enter');
    """,
    html: ~s(<label>Password <input type="password"></label>) do
    locator = Page.get_by_label(page, "Password")
    Locator.press_sequentially!(locator, "my password")
    Locator.press!(locator, "Enter")
  end

  example "Locator.screenshot",
    js: ~S"""
    await page.getByRole('link').screenshot({ animations: 'disabled', path: 'link.png' });
    """,
    html: ~s(<a href="/a">one</a>),
    writes: ["link.png"] do
    Page.get_by_role(page, :link) |> Locator.screenshot!(animations: :disabled, path: "link.png")
  end

  example "Locator.selectOption",
    js: ~S"""
    // single selection matching the value or label
    element.selectOption('blue');

    // single selection matching the label
    element.selectOption({ label: 'Blue' });

    // multiple selection for red, green and blue options
    element.selectOption(['red', 'green', 'blue']);
    """,
    html: """
    <select multiple>
      <option value="red">Red</option>
      <option value="green">Green</option>
      <option value="blue">Blue</option>
    </select>
    """,
    given: [element: Page.locator(page, "select")] do
    # single selection matching the value or label
    Locator.select_option!(element, "blue")

    # single selection matching the label
    Locator.select_option!(element, %{label: "Blue"})

    # multiple selection for red, green and blue options
    Locator.select_option!(element, ["red", "green", "blue"])
  end

  example "Locator.setInputFiles",
    js: ~S"""
    // Select one file
    await page.getByLabel('Upload file').setInputFiles(path.join(__dirname, 'myfile.pdf'));

    // Select multiple files
    await page.getByLabel('Upload files').setInputFiles([
      path.join(__dirname, 'file1.txt'),
      path.join(__dirname, 'file2.txt'),
    ]);

    // Select a directory
    await page.getByLabel('Upload directory').setInputFiles(path.join(__dirname, 'mydir'));

    // Remove all the selected files
    await page.getByLabel('Upload file').setInputFiles([]);

    // Upload buffer from memory
    await page.getByLabel('Upload file').setInputFiles({
      name: 'file.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('this is test')
    });
    """,
    # One input for "Upload file" and "Upload files": getByLabel matches substrings.
    html: """
    <input id="files" type="file" multiple>
    <label for="files">Upload file</label><label for="files">Upload files</label>
    <label>Upload directory <input type="file" webkitdirectory></label>
    """ do
    # Select one file
    Page.get_by_label(page, "Upload file") |> Locator.set_input_files!(Path.join(__DIR__, "myfile.pdf"))

    # Select multiple files
    Page.get_by_label(page, "Upload files")
    |> Locator.set_input_files!([Path.join(__DIR__, "file1.txt"), Path.join(__DIR__, "file2.txt")])

    # Select a directory
    Page.get_by_label(page, "Upload directory") |> Locator.set_input_files!(Path.join(__DIR__, "mydir"))

    # Remove all the selected files
    Page.get_by_label(page, "Upload file") |> Locator.set_input_files!([])

    # Upload buffer from memory
    Page.get_by_label(page, "Upload file")
    |> Locator.set_input_files!(%{name: "file.txt", mimeType: "text/plain", buffer: "this is test"})
  end

  example "Locator.waitFor",
    js: ~S"""
    const orderSent = page.locator('#order-sent');
    await orderSent.waitFor();
    """,
    html: ~s(<div id="order-sent">Order sent</div>) do
    order_sent = Page.locator(page, "#order-sent")
    Locator.wait_for!(order_sent)
  end

  example "Locator.waitForFunction",
    js: ~S"""
    const toggle = page.getByRole('button', { name: 'Menu' });
    await toggle.click();
    await toggle.waitForFunction(element => element.hasAttribute('aria-expanded'));
    """,
    html: ~s{<button onclick="this.setAttribute('aria-expanded', 'true')">Menu</button>} do
    toggle = Page.get_by_role(page, :button, name: "Menu")
    Locator.click!(toggle)
    Locator.wait_for_function!(toggle, "element => element.hasAttribute('aria-expanded')")
  end

  example "Locator.waitForFunction",
    js: ~S"""
    await page.getByTestId('status').waitForFunction((element, value) => {
      return element.textContent === value;
    }, 'Ready');
    """,
    html:
      ~s{<div data-testid="status">Loading</div><script>setTimeout(() => document.querySelector('div').textContent = 'Ready', 100)</script>} do
    Page.get_by_test_id(page, "status")
    |> Locator.wait_for_function!("(element, value) => element.textContent === value", "Ready")
  end

  example "Locator.within",
    js: ~S"""
    const thirdColumn = page.getByRole('cell').nth(2).within(page.getByRole('row'));
    await expect(thirdColumn).toHaveText(['Apple', 'Banana', 'Cherry']);
    """,
    html: """
    <table>
      <tr><td>1</td><td>a</td><td>Apple</td></tr>
      <tr><td>2</td><td>b</td><td>Banana</td></tr>
      <tr><td>3</td><td>c</td><td>Cherry</td></tr>
    </table>
    """ do
    third_column = Page.get_by_role(page, :cell) |> Locator.nth(2) |> Locator.within(Page.get_by_role(page, :row))
    Expect.to_have_text!(third_column, ["Apple", "Banana", "Cherry"])
  end
end
