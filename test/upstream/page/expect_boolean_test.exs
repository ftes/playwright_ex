defmodule PlaywrightEx.Page.ExpectBooleanTest do
  @upstream "tests/page/expect-boolean.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  describe "toBeChecked" do
    test "default", %{page: page} do
      Page.set_content!(page, "<input type=checkbox checked></input>")
      locator = Page.locator(page, "input")
      Expect.to_be_checked!(locator)
    end

    test "with checked:true", %{page: page} do
      Page.set_content!(page, "<input type=checkbox checked></input>")
      locator = Page.locator(page, "input")
      Expect.to_be_checked!(locator, checked: true)
    end

    test "with checked:false", %{page: page} do
      Page.set_content!(page, "<input type=checkbox checked></input>")
      locator = Page.locator(page, "input")
      Expect.not_to_be_checked!(locator, checked: false)
    end

    test "with indeterminate:true", %{page: page} do
      Page.set_content!(page, "<input type=checkbox></input>")
      Locator.evaluate!(Page.locator(page, "input"), "e => e.indeterminate = true")
      locator = Page.locator(page, "input")
      Expect.to_be_checked!(locator, indeterminate: true)
    end

    test "with indeterminate:true and checked", %{page: page} do
      Page.set_content!(page, "<input type=checkbox></input>")
      Locator.evaluate!(Page.locator(page, "input"), "e => e.indeterminate = true")
      locator = Page.locator(page, "input")
      {:error, error} = Expect.to_be_checked(locator, indeterminate: true, checked: false)
      assert error.message =~ "Can't assert indeterminate and checked at the same time"
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<input type=checkbox></input>")
      locator = Page.locator(page, "input")
      {:error, error} = Expect.to_be_checked(locator, timeout: 1000)

      assert error.message =~ """
             expect(locator).toBeChecked() failed

             Locator:  locator('input')
             Expected: checked
             Received: unchecked
             Timeout:  1000ms\
             """

      assert error.message =~ ~s|- Expect "toBeChecked" locator('input') with timeout 1000ms|
    end

    test "with not", %{page: page} do
      Page.set_content!(page, "<input type=checkbox></input>")
      locator = Page.locator(page, "input")
      Expect.not_to_be_checked!(locator)
    end

    test "with not and checked:false", %{page: page} do
      Page.set_content!(page, "<input type=checkbox></input>")
      locator = Page.locator(page, "input")
      Expect.to_be_checked!(locator, checked: false)
    end

    test "fail with not", %{page: page} do
      Page.set_content!(page, "<input type=checkbox checked></input>")
      locator = Page.locator(page, "input")
      {:error, error} = Expect.not_to_be_checked(locator, timeout: 1000)

      assert error.message =~ """
             expect(locator).not.toBeChecked() failed

             Locator:  locator('input')
             Expected: not checked
             Received: checked
             Timeout:  1000ms\
             """

      assert error.message =~ ~s|- Expect "not toBeChecked" locator('input') with timeout 1000ms|
      assert error.message =~ ~s(locator resolved to <input checked type="checkbox"/>)
    end

    test "fail with checked:false", %{page: page} do
      Page.set_content!(page, "<input type=checkbox checked></input>")
      locator = Page.locator(page, "input")
      {:error, error} = Expect.to_be_checked(locator, checked: false, timeout: 1000)

      assert error.message =~ """
             expect(locator).toBeChecked({ checked: false }) failed

             Locator:  locator('input')
             Expected: unchecked
             Received: checked
             Timeout:  1000ms\
             """

      assert error.message =~ ~s|- Expect "toBeChecked" locator('input') with timeout 1000ms|
      assert error.message =~ ~s(locator resolved to <input checked type="checkbox"/>)
    end

    test "fail with indeterminate: true", %{page: page} do
      Page.set_content!(page, "<input type=checkbox></input>")
      locator = Page.locator(page, "input")
      {:error, error} = Expect.to_be_checked(locator, indeterminate: true, timeout: 1000)

      assert error.message =~ """
             expect(locator).toBeChecked({ indeterminate: true }) failed

             Locator:  locator('input')
             Expected: indeterminate
             Received: unchecked
             Timeout:  1000ms\
             """

      assert error.message =~ ~s|- Expect "toBeChecked" locator('input') with timeout 1000ms|
    end

    test "fail missing", %{page: page} do
      Page.set_content!(page, "<div>no inputs here</div>")
      locator2 = Page.locator(page, "input2")
      {:error, error} = Expect.not_to_be_checked(locator2, timeout: 1000)

      assert error.message =~ """
             expect(locator).not.toBeChecked() failed

             Locator: locator('input2')
             Expected: not checked
             Timeout: 1000ms
             Error: element(s) not found

             Call log:
               - Expect "not toBeChecked" locator('input2') with timeout 1000ms
               - waiting for locator('input2')
             """
    end

    test "with role", %{page: page} do
      for role <- ["checkbox", "menuitemcheckbox", "option", "radio", "switch", "menuitemradio", "treeitem"] do
        # test.step("role=#{role}")
        Page.set_content!(page, "<div role=#{role} aria-checked=true>I am checked</div>")
        locator = Page.locator(page, "div")
        Expect.to_be_checked!(locator)
      end
    end

    test "friendly log", %{page: page} do
      Page.set_content!(page, "<input type=checkbox></input>")
      {:error, e} = Expect.to_be_checked(Page.locator(page, "input"), timeout: 1000)
      message1 = e.message
      assert message1 =~ ~s(unexpected value "unchecked")

      Page.set_content!(page, "<input type=checkbox checked></input>")
      {:error, e} = Expect.to_be_checked(Page.locator(page, "input"), checked: false, timeout: 1000)
      message2 = e.message
      assert message2 =~ ~s(unexpected value "checked")
    end

    test "with impossible timeout", %{page: page} do
      Page.set_content!(page, "<input type=checkbox checked></input>")
      Expect.to_be_checked!(Page.locator(page, "input"), timeout: 1)
    end

    test "with impossible timeout .not", %{page: page} do
      Page.set_content!(page, "<input type=checkbox></input>")
      Expect.not_to_be_checked!(Page.locator(page, "input"), timeout: 1)
    end
  end

  describe "toBeEditable" do
    test "default", %{page: page} do
      Page.set_content!(page, "<input></input>")
      locator = Page.locator(page, "input")
      Expect.to_be_editable!(locator)
    end

    test "with not", %{page: page} do
      Page.set_content!(page, "<input readonly></input>")
      locator = Page.locator(page, "input")
      Expect.not_to_be_editable!(locator)
    end

    test "with editable:true", %{page: page} do
      Page.set_content!(page, "<input></input>")
      locator = Page.locator(page, "input")
      Expect.to_be_editable!(locator, editable: true)
    end

    test "with editable:false", %{page: page} do
      Page.set_content!(page, "<input readonly></input>")
      locator = Page.locator(page, "input")
      Expect.to_be_editable!(locator, editable: false)
    end

    test "with not and editable:false", %{page: page} do
      Page.set_content!(page, "<input></input>")
      locator = Page.locator(page, "input")
      Expect.not_to_be_editable!(locator, editable: false)
    end

    test "throws", %{page: page} do
      Page.set_content!(page, "<button>")
      locator = Page.locator(page, "button")
      {:error, error} = Expect.to_be_editable(locator)

      assert Exception.message(error) =~
               "Element is not an <input>, <textarea>, <select> or [contenteditable] and does not have a role allowing [aria-readonly]"
    end
  end

  describe "toBeEnabled" do
    test "default", %{page: page} do
      Page.set_content!(page, "<button>Text</button>")
      locator = Page.locator(page, "button")
      Expect.to_be_enabled!(locator)
    end

    test "with enabled:true", %{page: page} do
      Page.set_content!(page, "<button>Text</button>")
      locator = Page.locator(page, "button")
      Expect.to_be_enabled!(locator, enabled: true)
    end

    test "with enabled:false", %{page: page} do
      Page.set_content!(page, "<button disabled>Text</button>")
      locator = Page.locator(page, "button")
      Expect.to_be_enabled!(locator, enabled: false)
    end

    test "failed", %{page: page} do
      Page.set_content!(page, "<button disabled>Text</button>")
      locator = Page.locator(page, "button")
      {:error, error} = Expect.to_be_enabled(locator, timeout: 1000)
      assert error.message =~ "locator resolved to <button disabled>Text</button>"
    end

    test "eventually", %{page: page} do
      Page.set_content!(page, "<button disabled>Text</button>")
      locator = Page.locator(page, "button")

      Task.start(fn ->
        Process.sleep(500)
        Locator.evaluate(locator, "e => e.removeAttribute('disabled')")
      end)

      Expect.to_be_enabled!(locator)
    end

    test "eventually with not", %{page: page} do
      Page.set_content!(page, "<button>Text</button>")
      locator = Page.locator(page, "button")

      Task.start(fn ->
        Process.sleep(500)
        Locator.evaluate(locator, "e => e.setAttribute('disabled', '')")
      end)

      Expect.not_to_be_enabled!(locator)
    end

    test "with not and enabled:false", %{page: page} do
      Page.set_content!(page, "<button>Text</button>")
      locator = Page.locator(page, "button")
      Expect.not_to_be_enabled!(locator, enabled: false)
    end

    test "toBeDisabled", %{page: page} do
      Page.set_content!(page, "<button disabled>Text</button>")
      locator = Page.locator(page, "button")
      Expect.to_be_disabled!(locator)
    end
  end

  test "toBeEmpty input", %{page: page} do
    Page.set_content!(page, "<input></input>")
    locator = Page.locator(page, "input")
    Expect.to_be_empty!(locator)
  end

  test "not.toBeEmpty", %{page: page} do
    Page.set_content!(page, "<input value=text></input>")
    locator = Page.locator(page, "input")
    Expect.not_to_be_empty!(locator)
  end

  test "toBeEmpty div", %{page: page} do
    Page.set_content!(page, ~s(<div style="width: 50; height: 50px"></div>))
    locator = Page.locator(page, "div")
    Expect.to_be_empty!(locator)
  end

  test "toBeDisabled with value", %{page: page} do
    Page.set_content!(page, ~s(<button disabled="yes">Text</button>))
    locator = Page.locator(page, "button")
    Expect.to_be_disabled!(locator)
  end

  test "toBeChecked with value", %{page: page} do
    Page.set_content!(page, ~s(<input type=checkbox checked="yes"></input>))
    locator = Page.locator(page, "input")
    Expect.to_be_checked!(locator)
  end

  test "toBeHidden with value", %{page: page} do
    Page.set_content!(page, ~s(<input type=checkbox hidden="of course"></input>))
    locator = Page.locator(page, "input")
    Expect.to_be_hidden!(locator)
  end

  test "not.toBeDisabled div", %{page: page} do
    Page.set_content!(page, ~s(<div disabled="yes"></div>))
    locator = Page.locator(page, "div")
    Expect.not_to_be_disabled!(locator)
  end

  describe "toBeVisible" do
    test "default", %{page: page} do
      Page.set_content!(page, "<input></input>")
      locator = Page.locator(page, "input")
      Expect.to_be_visible!(locator)
    end

    test "with not", %{page: page} do
      Page.set_content!(page, ~s(<button style="display: none">hello</button>))
      locator = Page.locator(page, "button")
      Expect.not_to_be_visible!(locator)
    end

    test "with visible:true", %{page: page} do
      Page.set_content!(page, "<button>hello</button>")
      locator = Page.locator(page, "button")
      Expect.to_be_visible!(locator, visible: true)
    end

    test "with visible:false", %{page: page} do
      Page.set_content!(page, "<button hidden>hello</button>")
      locator = Page.locator(page, "button")
      Expect.to_be_visible!(locator, visible: false)
    end

    test "with not and visible:false", %{page: page} do
      Page.set_content!(page, "<button>hello</button>")
      locator = Page.locator(page, "button")
      Expect.not_to_be_visible!(locator, visible: false)
    end

    test "eventually", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = Page.locator(page, "span")

      Task.start(fn ->
        Page.eval_on_selector(page, "div", "div => div.innerHTML = '<span>Hello</span>'")
      end)

      Expect.to_be_visible!(locator)
    end

    test "eventually with not", %{page: page} do
      Page.set_content!(page, "<div><span>Hello</span></div>")
      locator = Page.locator(page, "span")

      Task.start(fn ->
        Page.eval_on_selector(page, "span", "span => span.textContent = ''")
      end)

      Expect.not_to_be_visible!(locator)
    end

    test "fail", %{page: page} do
      Page.set_content!(page, ~s(<button style="display: none"></button>))
      locator = Page.locator(page, "button")
      {:error, error} = Expect.to_be_visible(locator, timeout: 1000)
      assert error.message =~ "locator resolved to <button></button>"
    end

    test "fail with not", %{page: page} do
      Page.set_content!(page, "<input></input>")
      locator = Page.locator(page, "input")
      {:error, error} = Expect.not_to_be_visible(locator, timeout: 1000)
      assert error.message =~ "locator resolved to <input/>"
    end

    test "with impossible timeout", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      Expect.to_be_visible!(Page.locator(page, "#node"), timeout: 1)
    end

    test "with impossible timeout .not", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      Expect.not_to_be_visible!(Page.locator(page, "no-such-thing"), timeout: 1)
    end

    test "with frameLocator", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("input")
      promise = Task.async(fn -> Expect.to_be_visible!(locator) end)
      Page.wait_for_timeout!(page, 1000)
      assert Task.yield(promise, 0) == nil
      Page.set_content!(page, ~s(<iframe srcdoc="<input>"></iframe>))
      assert Task.await(promise) == :ok
    end

    test "with frameLocator 2", %{page: page} do
      Page.set_content!(page, "<iframe></iframe>")
      locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("input")
      promise = Task.async(fn -> Expect.to_be_visible!(locator) end)
      Page.wait_for_timeout!(page, 1000)
      assert Task.yield(promise, 0) == nil
      Page.set_content!(page, ~s(<iframe srcdoc="<input>"></iframe>))
      assert Task.await(promise) == :ok
    end

    test "over navigation", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      promise = Task.async(fn -> Expect.to_be_visible!(Page.locator(page, "input")) end)
      Page.wait_for_timeout!(page, 1000)
      assert Task.yield(promise, 0) == nil
      Page.goto!(page, server.prefix <> "/input/checkbox.html")
      assert Task.await(promise) == :ok
    end
  end

  describe "toBeHidden" do
    test "default", %{page: page} do
      Page.set_content!(page, ~s(<button style="display: none"></button>))
      locator = Page.locator(page, "button")
      Expect.to_be_hidden!(locator)
    end

    test "when nothing matches", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = Page.locator(page, "button")
      Expect.to_be_hidden!(locator)
    end

    test "with not", %{page: page} do
      Page.set_content!(page, "<input></input>")
      locator = Page.locator(page, "input")
      Expect.not_to_be_hidden!(locator)
    end

    test "eventually with not", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = Page.locator(page, "span")

      Task.start(fn ->
        Page.eval_on_selector(page, "div", "div => div.innerHTML = '<span>Hello</span>'")
      end)

      Expect.not_to_be_hidden!(locator)
    end

    test "eventually", %{page: page} do
      Page.set_content!(page, "<div><span>Hello</span></div>")
      locator = Page.locator(page, "span")

      Task.start(fn ->
        Page.eval_on_selector(page, "span", "span => span.textContent = ''")
      end)

      Expect.to_be_hidden!(locator)
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<input></input>")
      locator = Page.locator(page, "input")
      {:error, error} = Expect.to_be_hidden(locator, timeout: 3000)
      assert error.message =~ "locator resolved to <input/>"
    end

    test "fail with not", %{page: page} do
      Page.set_content!(page, ~s(<button style="display: none"></button>))
      locator = Page.locator(page, "button")
      {:error, error} = Expect.not_to_be_hidden(locator, timeout: 3000)
      assert error.message =~ "locator resolved to <button></button>"
    end

    test "fail with not when nothing matching", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = Page.locator(page, "button")
      {:error, error} = Expect.not_to_be_hidden(locator, timeout: 1000)

      assert error.message =~ """
             expect(locator).not.toBeHidden() failed

             Locator: locator('button')
             Expected: not hidden
             Timeout: 1000ms
             Error: element(s) not found

             Call log:
               - Expect "not toBeHidden" locator('button') with timeout 1000ms
             """
    end

    test "with impossible timeout .not", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      Expect.not_to_be_hidden!(Page.locator(page, "#node"), timeout: 1)
    end

    test "with impossible timeout", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      Expect.to_be_hidden!(Page.locator(page, "no-such-thing"), timeout: 1)
    end
  end

  test "toBeFocused", %{page: page} do
    Page.set_content!(page, "<input></input>")
    locator = Page.locator(page, "input")
    Locator.focus!(locator)
    Expect.to_be_focused!(locator)
  end

  test "toBeFocused with shadow elements", %{page: page} do
    Page.set_content!(page, """
        <div id="app">
        </div>
        <script>
          const root = document.querySelector('div');
          const shadowRoot = root.attachShadow({ mode: 'open' });
          const input = document.createElement('input');
          input.id = "my-input"
          shadowRoot.appendChild(input);
        </script>
    """)

    page |> Page.locator("input") |> Locator.focus!()
    assert Page.evaluate!(page, "() => document.activeElement.shadowRoot.activeElement.id") == "my-input"
    Expect.to_be_focused!(Page.locator(page, "#app"))
    Expect.to_be_focused!(Page.locator(page, "input"))
  end

  test "should print unknown engine error", %{page: page} do
    {:error, error} = Expect.to_be_visible(Page.locator(page, ~s(row="row")))
    assert Exception.message(error) =~ ~s(Unknown engine "row" while parsing selector row="row")
  end

  test "should print selector syntax error", %{page: page} do
    {:error, error} = Expect.to_be_visible(Page.locator(page, "row]"))
    assert Exception.message(error) =~ ~s(Unexpected token "]" while parsing css selector "row]")
  end

  test "toBeOK", %{page: page, server: server} do
    res = APIRequestContext.get!(Page.request(page), server.empty_page)
    Expect.to_be_ok!(res)
  end

  test "not.toBeOK", %{page: page, server: server} do
    res = APIRequestContext.get!(Page.request(page), "#{server.prefix}/unknown")
    Expect.not_to_be_ok!(res)
  end

  test "toBeOK fail with invalid argument", %{page: page} do
    # (expect(page) as any): the facade's typespec says APIResponse, the matcher checks at runtime.
    {:error, error} = Expect.to_be_ok(page)
    assert Exception.message(error) =~ "toBeOK can be only used with APIResponse object"
  end

  @tag skip: "not ported: a pending promise as receiver (Elixir calls return values)"
  test "toBeOK fail with promise"

  describe "toBeOK should print response with text content type when fails" do
    setup %{server: server} do
      TestServer.set_route(server, "/text-content-type", fn conn ->
        conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.send_resp(404, "Text error")
      end)

      TestServer.set_route(server, "/no-content-type", &Plug.Conn.send_resp(&1, 404, "No content type error"))

      TestServer.set_route(server, "/binary-content-type", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/bmp")
        |> Plug.Conn.send_resp(404, "Image content type error")
      end)

      :ok
    end

    test "text content type", %{page: page, server: server} do
      res = APIRequestContext.get!(Page.request(page), "#{server.prefix}/text-content-type")
      {:error, error} = Expect.to_be_ok(res)
      assert Exception.message(error) =~ "expect(response).toBeOK() failed"
      assert Exception.message(error) =~ "→ GET #{server.prefix}/text-content-type"
      assert Exception.message(error) =~ "← 404 Not Found"
      assert Exception.message(error) =~ "Response text:\nText error"
    end

    test "no content type", %{page: page, server: server} do
      res = APIRequestContext.get!(Page.request(page), "#{server.prefix}/no-content-type")
      {:error, error} = Expect.to_be_ok(res)
      assert Exception.message(error) =~ "→ GET #{server.prefix}/no-content-type"
      assert Exception.message(error) =~ "← 404 Not Found"
      refute Exception.message(error) =~ "No content type error"
    end

    test "image content type", %{page: page, server: server} do
      res = APIRequestContext.get!(Page.request(page), "#{server.prefix}/image-content-type")
      {:error, error} = Expect.to_be_ok(res)
      assert Exception.message(error) =~ "→ GET #{server.prefix}/image-content-type"
      assert Exception.message(error) =~ "← 404 Not Found"
      refute Exception.message(error) =~ "Image content type error"
    end
  end

  describe "toBeAttached" do
    test "default", %{page: page} do
      Page.set_content!(page, "<input></input>")
      locator = Page.locator(page, "input")
      Expect.to_be_attached!(locator)
    end

    test "with hidden element", %{page: page} do
      Page.set_content!(page, ~s(<button style="display:none">hello</button>))
      locator = Page.locator(page, "button")
      Expect.to_be_attached!(locator)
    end

    test "with not", %{page: page} do
      Page.set_content!(page, "<button>hello</button>")
      locator = Page.locator(page, "input")
      Expect.not_to_be_attached!(locator)
    end

    test "with attached:true", %{page: page} do
      Page.set_content!(page, "<button>hello</button>")
      locator = Page.locator(page, "button")
      Expect.to_be_attached!(locator, attached: true)
    end

    test "with attached:false", %{page: page} do
      Page.set_content!(page, "<button>hello</button>")
      locator = Page.locator(page, "input")
      Expect.to_be_attached!(locator, attached: false)
    end

    test "with not and attached:false", %{page: page} do
      Page.set_content!(page, "<button>hello</button>")
      locator = Page.locator(page, "button")
      Expect.not_to_be_attached!(locator, attached: false)
    end

    test "eventually", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = Page.locator(page, "span")

      Task.start(fn ->
        Page.eval_on_selector(page, "div", "div => div.innerHTML = '<span>Hello</span>'")
      end)

      Expect.to_be_attached!(locator)
    end

    test "eventually with not", %{page: page} do
      Page.set_content!(page, "<div><span>Hello</span></div>")
      locator = Page.locator(page, "span")

      Task.start(fn ->
        Page.eval_on_selector(page, "div", "div => div.textContent = ''")
      end)

      Expect.not_to_be_attached!(locator)
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<button>Hello</button>")
      locator = Page.locator(page, "input")
      {:error, error} = Expect.to_be_attached(locator, timeout: 1000)
      refute error.message =~ "locator resolved to"
    end

    test "fail with not", %{page: page} do
      Page.set_content!(page, "<input></input>")
      locator = Page.locator(page, "input")
      {:error, error} = Expect.not_to_be_attached(locator, timeout: 3000)
      assert error.message =~ "locator resolved to <input/>"
    end

    test "with impossible timeout", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      Expect.to_be_attached!(Page.locator(page, "#node"), timeout: 1)
    end

    test "with impossible timeout .not", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      Expect.not_to_be_attached!(Page.locator(page, "no-such-thing"), timeout: 1)
    end

    test "with frameLocator", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("input")
      promise = Task.async(fn -> Expect.to_be_attached!(locator) end)
      Page.wait_for_timeout!(page, 1000)
      assert Task.yield(promise, 0) == nil
      Page.set_content!(page, ~s(<iframe srcdoc="<input>"></iframe>))
      assert Task.await(promise) == :ok
    end

    test "over navigation", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      promise = Task.async(fn -> Expect.to_be_attached!(Page.locator(page, "input")) end)
      Page.wait_for_timeout!(page, 1000)
      assert Task.yield(promise, 0) == nil
      Page.goto!(page, server.prefix <> "/input/checkbox.html")
      assert Task.await(promise) == :ok
    end
  end
end
