defmodule PlaywrightEx.Page.PageFillTest do
  @upstream "tests/page/page-fill.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  import PlaywrightEx.Utils, only: [rafraf: 2]

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise

  @moduletag :page

  defp windows?, do: match?({:win32, _}, :os.type())

  defp give_it_a_chance_to_fill(page), do: rafraf(page, 5)

  test "should fill textarea @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.fill!(page, "textarea", "some value")
    assert Page.evaluate!(page, "() => window['result']") == "some value"
  end

  test "should fill input", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.fill!(page, "input", "some value")
    assert Page.evaluate!(page, "() => window['result']") == "some value"
  end

  test "should throw on unsupported inputs", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")

    for type <- ["button", "checkbox", "file", "image", "radio", "reset", "submit"] do
      Page.eval_on_selector!(page, "input", "(input, type) => input.setAttribute('type', type)", type)
      {:error, error} = Page.fill(page, "input", "")
      assert Exception.message(error) =~ ~s(Input of type "#{type}" cannot be filled)
    end
  end

  test "should fill different input types", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")

    for type <- ["password", "search", "tel", "text", "url", "invalid-type"] do
      Page.eval_on_selector!(page, "input", "(input, type) => input.setAttribute('type', type)", type)
      Page.fill!(page, "input", "text " <> type)
      assert Page.evaluate!(page, "() => window['result']") == "text " <> type
    end
  end

  test "should fill range input", %{page: page} do
    Page.set_content!(page, "<input type=range min=0 max=100 value=50>")
    Page.fill!(page, "input", "42")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "42"
  end

  test "should throw on incorrect range value", %{page: page} do
    Page.set_content!(page, "<input type=range min=0 max=100 value=50>")
    {:error, error1} = Page.fill(page, "input", "foo")
    assert Exception.message(error1) =~ "Malformed value"
    {:error, error2} = Page.fill(page, "input", "200")
    assert Exception.message(error2) =~ "Malformed value"
    {:error, error3} = Page.fill(page, "input", "15.43")
    assert Exception.message(error3) =~ "Malformed value"
  end

  test "should fill color input", %{page: page} do
    Page.set_content!(page, ~s(<input type=color value="#e66465">))
    Page.fill!(page, "input", "#aaaaaa")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "#aaaaaa"
  end

  test "should fill color input case insensitive", %{page: page, browser_name: browser_name} do
    Page.set_content!(page, ~s(<input type=color value="#e66465">))
    Page.fill!(page, "input", "#AbCd00")

    # channel !== 'webkit-wsl': no channels here.
    if browser_name == "webkit" and windows?(),
      do: assert(Page.eval_on_selector!(page, "input", "input => input.value") == "#AbCd00"),
      else: assert(Page.eval_on_selector!(page, "input", "input => input.value") == "#abcd00")
  end

  @tag skip:
         if(@browser_name == "webkit" and match?({:win32, _}, :os.type()),
           do: "upstream skip: WebKit win does not support color inputs"
         )
  test "should throw on incorrect color value", %{page: page} do
    # it.skip(browserName === 'webkit' && isWindows, 'WebKit win does not support color inputs')
    Page.set_content!(page, ~s(<input type=color value="#e66465">))
    {:error, error1} = Page.fill(page, "input", "badvalue")
    assert Exception.message(error1) =~ "Malformed value"
  end

  test "should fill date input after clicking", %{page: page} do
    Page.set_content!(page, "<input type=date>")
    Page.click!(page, "input")
    Page.fill!(page, "input", "2020-03-02")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "2020-03-02"
  end

  for {type, value} <- [
        {"color", "#aaaaaa"},
        {"date", "2020-03-02"},
        {"time", "13:15"},
        {"datetime-local", "2020-03-02T13:15:30"},
        {"month", "2020-03"},
        {"range", "42"},
        {"week", "2020-W50"}
      ] do
    @type_ type
    @value value
    # https://github.com/microsoft/playwright/issues/28726
    @tag skip:
           if(
             (@browser_name != "chromium" and @type_ in ["month", "week"]) or
               (@browser_name == "webkit" and match?({:win32, _}, :os.type()) and
                  @type_ in ["color", "date", "time", "datetime-local"]),
             do: "upstream skip: Some browser/platforms do not implement certain input types"
           )
    test "input event.composed should be true and cross shadow dom boundary - #{type}",
         %{page: page, server: server} do
      Page.goto!(page, server.empty_page)

      Page.set_content!(page, """
      <body><script>
      const div = document.createElement('div');
      const shadowRoot = div.attachShadow({mode: 'open'});
      shadowRoot.innerHTML = '<input type=#{@type_}></input>';
      document.body.appendChild(div);
      </script></body>
      """)

      page
      |> Page.locator("body")
      |> Locator.evaluate!("""
      select => {
        window.firedBodyEvents = [];
        for (const event of ['input', 'change']) {
          select.addEventListener(event, e => {
            window.firedBodyEvents.push(e.type + ':' + e.composed);
          }, false);
        }
      }
      """)

      page
      |> Page.locator("input")
      |> Locator.evaluate!("""
      select => {
        window.firedEvents = [];
        for (const event of ['input', 'change']) {
          select.addEventListener(event, e => {
            window.firedEvents.push(e.type + ':' + e.composed);
          }, false);
        }
      }
      """)

      page |> Page.locator("input") |> Locator.fill!(@value)

      assert Page.evaluate!(page, "() => window['firedEvents']") == ["input:true", "change:false"]
      assert Page.evaluate!(page, "() => window['firedBodyEvents']") == ["input:true"]
    end
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream skip: WebKit does not support date inputs")
  test "should throw on incorrect date", %{page: page} do
    # it.skip(browserName === 'webkit', 'WebKit does not support date inputs')
    Page.set_content!(page, "<input type=date>")
    {:error, error} = Page.fill(page, "input", "2020-13-05")
    assert Exception.message(error) =~ "Malformed value"
  end

  test "should fill time input", %{page: page} do
    Page.set_content!(page, "<input type=time>")
    Page.fill!(page, "input", "13:15")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "13:15"
  end

  test "should fill month input", %{page: page} do
    Page.set_content!(page, "<input type=month>")
    Page.fill!(page, "input", "2020-07")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "2020-07"
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: Only Chromium supports month inputs")
  test "should throw on incorrect month", %{page: page} do
    # it.skip(browserName !== 'chromium', 'Only Chromium supports month inputs')
    Page.set_content!(page, "<input type=month>")
    {:error, error} = Page.fill(page, "input", "2020-13")
    assert Exception.message(error) =~ "Malformed value"
  end

  test "should fill week input", %{page: page} do
    Page.set_content!(page, "<input type=week>")
    Page.fill!(page, "input", "2020-W50")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "2020-W50"
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: Only Chromium supports week inputs")
  test "should throw on incorrect week", %{page: page} do
    # it.skip(browserName !== 'chromium', 'Only Chromium supports week inputs')
    Page.set_content!(page, "<input type=week>")
    {:error, error} = Page.fill(page, "input", "2020-123")
    assert Exception.message(error) =~ "Malformed value"
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream skip: WebKit does not support time inputs")
  test "should throw on incorrect time", %{page: page} do
    # it.skip(browserName === 'webkit', 'WebKit does not support time inputs')
    Page.set_content!(page, "<input type=time>")
    {:error, error} = Page.fill(page, "input", "25:05")
    assert Exception.message(error) =~ "Malformed value"
  end

  test "should fill datetime-local input", %{page: page} do
    Page.set_content!(page, "<input type=datetime-local>")
    Page.fill!(page, "input", "2020-03-02T05:15")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "2020-03-02T05:15"
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: Only Chromium supports datetime-local inputs")
  test "should throw on incorrect datetime-local", %{page: page} do
    # it.skip(browserName !== 'chromium', 'Only Chromium supports datetime-local inputs')
    Page.set_content!(page, "<input type=datetime-local>")
    {:error, error} = Page.fill(page, "input", "abc")
    assert Exception.message(error) =~ "Malformed value"
  end

  test "should fill contenteditable", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.fill!(page, "div[contenteditable]", "some value")
    assert Page.eval_on_selector!(page, "div[contenteditable]", "div => div.textContent") == "some value"
  end

  # it.fixme(browserName === 'firefox' && !isBidi): Firefox does not handle new lines in contenteditable.
  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: Firefox does not handle new lines in contenteditable")
  test "should fill contenteditable with new lines", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<div contenteditable="true"></div>))
    page |> Page.locator("div[contenteditable]") |> Locator.fill!("John\nDoe")
    assert page |> Page.locator("div[contenteditable]") |> Locator.inner_text!() == "John\nDoe"
  end

  # https://github.com/microsoft/playwright/issues/36715
  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: firefox (non-BiDi)")
  test "should not double-fill in contenteditable with beforeinput handler in Firefox", %{
    page: page
  } do
    # it.fixme(browserName === 'firefox' && !isBidi)
    Page.set_content!(page, """
    <div id="editor" contenteditable="true"></div>
    <script>
      const editor = document.getElementById('editor');
      editor.addEventListener('beforeinput', (event) => {
        event.preventDefault();
        editor.textContent = event.data;
      });
    </script>
    """)

    locator = Page.locator(page, "#editor")
    test_value = "Playwright"
    Locator.fill!(locator, test_value)
    Expect.to_have_text!(locator, test_value)
  end

  test "should fill elements with existing value and selection", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")

    Page.eval_on_selector!(page, "input", "input => input.value = 'value one'")
    Page.fill!(page, "input", "another value")
    assert Page.evaluate!(page, "() => window['result']") == "another value"

    Page.eval_on_selector!(page, "input", """
    input => {
      input.selectionStart = 1;
      input.selectionEnd = 2;
    }
    """)

    Page.fill!(page, "input", "maybe this one")
    assert Page.evaluate!(page, "() => window['result']") == "maybe this one"

    Page.eval_on_selector!(page, "div[contenteditable]", """
    div => {
      div.innerHTML = 'some text <span>some more text<span> and even more text';
      const range = document.createRange();
      range.selectNodeContents(div.querySelector('span'));
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
    """)

    Page.fill!(page, "div[contenteditable]", "replace with this")
    assert Page.eval_on_selector!(page, "div[contenteditable]", "div => div.textContent") == "replace with this"
  end

  test "should throw nice error without injected script stack when element is not an <input>", %{page: page} do
    Page.set_content!(page, "<select><option>value1</option></select>")
    {:error, error} = Page.fill(page, "select", "")

    assert Exception.message(error) =~
             "page.fill: Error: Element is not an <input>, <textarea> or [contenteditable] element\nCall log:"
  end

  test "should throw if passed a non-string value", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    {:error, error} = Page.fill(page, "textarea", 123)
    assert Exception.message(error) =~ "value: expected string, got number"
  end

  test "should retry on disabled element", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.eval_on_selector!(page, "input", "i => i.disabled = true")

    task = Task.async(fn -> Page.fill!(page, "input", "some value") end)
    give_it_a_chance_to_fill(page)
    assert Task.yield(task, 0) == nil
    assert Page.evaluate!(page, "() => window['result']") == ""

    Page.eval_on_selector!(page, "input", "i => i.disabled = false")
    Task.await(task, :infinity)
    assert Page.evaluate!(page, "() => window['result']") == "some value"
  end

  test "should retry on readonly element", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.eval_on_selector!(page, "textarea", "i => i.readOnly = true")

    task = Task.async(fn -> Page.fill!(page, "textarea", "some value") end)
    give_it_a_chance_to_fill(page)
    assert Task.yield(task, 0) == nil
    assert Page.evaluate!(page, "() => window['result']") == ""

    Page.eval_on_selector!(page, "textarea", "i => i.readOnly = false")
    Task.await(task, :infinity)
    assert Page.evaluate!(page, "() => window['result']") == "some value"
  end

  test "should retry on invisible element", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.eval_on_selector!(page, "input", "i => i.style.display = 'none'")

    task = Task.async(fn -> Page.fill!(page, "input", "some value") end)
    give_it_a_chance_to_fill(page)
    assert Task.yield(task, 0) == nil
    assert Page.evaluate!(page, "() => window['result']") == ""

    Page.eval_on_selector!(page, "input", "i => i.style.display = 'inline'")
    Task.await(task, :infinity)
    assert Page.evaluate!(page, "() => window['result']") == "some value"
  end

  test "should be able to fill the body", %{page: page} do
    Page.set_content!(page, ~s(<body contentEditable="true"></body>))
    Page.fill!(page, "body", "some value")
    assert Page.evaluate!(page, "() => document.body.textContent") == "some value"
  end

  test "should fill fixed position input", %{page: page} do
    Page.set_content!(page, "<input style='position: fixed;' />")
    Page.fill!(page, "input", "some value")
    assert Page.evaluate!(page, "() => document.querySelector('input').value") == "some value"
  end

  test "should be able to fill when focus is in the wrong frame", %{page: page} do
    Page.set_content!(page, """
    <div contentEditable="true"></div>
    <iframe></iframe>
    """)

    Page.focus!(page, "iframe")
    Page.fill!(page, "div", "some value")
    assert Page.eval_on_selector!(page, "div", "d => d.textContent") == "some value"
  end

  test "should be able to fill the input[type=number]", %{page: page} do
    Page.set_content!(page, ~s(<input id="input" type="number"></input>))
    Page.fill!(page, "input", "42")
    assert Page.evaluate!(page, "() => window['input'].value") == "42"
  end

  test "should be able to fill exponent into the input[type=number]", %{page: page} do
    Page.set_content!(page, ~s(<input id="input" type="number"></input>))
    Page.fill!(page, "input", "-10e5")
    assert Page.evaluate!(page, "() => window['input'].value") == "-10e5"
  end

  test "should be able to fill input[type=number] with empty string", %{page: page} do
    Page.set_content!(page, ~s(<input id="input" type="number" value="123"></input>))
    Page.fill!(page, "input", "")
    assert Page.evaluate!(page, "() => window['input'].value") == ""
  end

  test "should not be able to fill text into the input[type=number]", %{page: page} do
    Page.set_content!(page, ~s(<input id="input" type="number"></input>))
    {:error, error} = Page.fill(page, "input", "abc")
    assert Exception.message(error) =~ "Cannot type text into input[type=number]"
  end

  test "should be able to clear using fill()", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.fill!(page, "input", "some value")
    assert Page.evaluate!(page, "() => window['result']") == "some value"
    Page.fill!(page, "input", "")
    assert Page.evaluate!(page, "() => window['result']") == ""
  end

  test "should not throw when fill causes navigation", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.set_content!(page, "<input type=date>")

    Page.eval_on_selector!(
      page,
      "input",
      "select => select.addEventListener('input', () => window.location.href = '/empty.html')"
    )

    navigation = Page.wait_for_navigation(page)
    Page.fill!(page, "input", "2020-03-02")
    Promise.await!(navigation)
    assert Page.url(page) =~ "empty.html"
  end

  # https://github.com/microsoft/playwright/issues/15925
  test "fill back to back", %{page: page} do
    Page.set_content!(page, ~s(<input id="one"></input><input id="two"></input>))
    Page.fill!(page, "id=one", "first value")
    Page.fill!(page, "id=two", "second value")
    Expect.to_have_value!(Page.locator(page, "id=one"), "first value")
    Expect.to_have_value!(Page.locator(page, "id=two"), "second value")
  end

  # https://github.com/microsoft/playwright/issues/39492
  test "should fill contenteditable with focus handler that collapses selection", %{page: page} do
    Page.set_content!(page, """
    <div contenteditable="true">initial text</div>
    <script>
      const editor = document.querySelector('[contenteditable]');
      editor.addEventListener('focus', () => {
        const selection = window.getSelection();
        if (selection.rangeCount > 0)
          selection.collapseToEnd();
      });
    </script>
    """)

    Page.fill!(page, "div[contenteditable]", "some value")
    assert page |> Page.locator("div[contenteditable]") |> Locator.text_content!() == "some value"
  end
end
