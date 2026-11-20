defmodule Playwright.Guides.ApiConventionsTest do
  # The snippets of `guides/introduction/api-conventions.md`, run against the facade.
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.BrowserType
  alias Playwright.ConsoleMessage
  alias Playwright.Expect
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.Promise
  alias Playwright.Request
  alias Playwright.Response
  alias Playwright.Route
  alias Playwright.TestBrowser
  alias Playwright.TimeoutError

  @moduletag :tmp_dir

  @html """
  <!doctype html>
  <title>Home</title>
  <button onclick="document.querySelector('.status').textContent = 'Saved'">Save</button>
  <input type="submit" value="Submit order">
  <input name="email" disabled>
  <p class="status"></p>
  <p>a b</p>
  <a href="/popup" target="_blank">Open</a>
  """

  setup_all do
    start_supervised!({Playwright.Supervisor, name: __MODULE__})
    browser = BrowserType.launch!(TestBrowser.browser_type(Playwright.instance(__MODULE__)))
    %{browser: browser}
  end

  setup %{browser: browser} do
    context = Browser.new_context!(browser, base_url: "http://app.test")
    on_exit(fn -> BrowserContext.close(context) end)

    BrowserContext.route!(context, "http://app.test/**", fn route, request ->
      case URI.parse(Request.url(request)).path do
        "/admin" -> Route.abort!(route)
        _ -> Route.fulfill!(route, body: @html, content_type: "text/html")
      end
    end)

    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/")
    %{context: context, page: page}
  end

  test "names", %{page: page} do
    Page.get_by_role(page, :button, name: "Save") |> Locator.click!()
    assert Page.eval_on_selector!(page, ".status", "el => el.textContent") == "Saved"
    assert %Playwright.Keyboard{} = Page.keyboard(page)

    request = Page.expect_request!(page, "**/x", fn -> Page.evaluate!(page, "() => fetch('/x')") end)
    assert Request.url(request) == "http://app.test/x"
  end

  test "results", %{page: page} do
    title = Page.title!(page)
    assert title == "Home"

    result =
      case Page.goto(page, "/") do
        {:ok, response} -> Response.status(response)
        {:error, %Playwright.TimeoutError{}} -> :timeout
      end

    assert result == 200
    assert {:error, %Playwright.PlaywrightError{}} = Page.goto(page, "/admin")
  end

  test "options", %{browser: browser, page: page, tmp_dir: tmp_dir} do
    # The guide writes to "shot.png" in the working directory.
    path = Path.join(tmp_dir, "shot.png")
    Page.screenshot!(page, path: path, full_page: true)
    assert File.exists?(path)

    context = Browser.new_context!(browser, viewport: %{width: 1280, height: 720})

    BrowserContext.add_cookies!(context, [
      %{name: "session", value: "abc", url: "https://example.com", sameSite: "Lax"}
    ])

    [%{name: "session", sameSite: "Lax"}] = BrowserContext.cookies!(context)
    Page.set_extra_http_headers!(page, %{"x-request-id" => "42"})
    BrowserContext.close!(context)

    assert_raise ArgumentError, fn -> Page.screenshot(page, full_pag: true) end

    [{:button, %{doc: "Defaults to `:left`.", since: nil, spec: spec}} | _] = Locator.__options__(:click)
    assert Macro.to_string(spec) == ":left | :right | :middle"
  end

  test "enums and :null", %{page: page} do
    Page.emulate_media!(page, color_scheme: :dark)
    assert Page.evaluate!(page, "matchMedia('(prefers-color-scheme: dark)').matches")
    Page.emulate_media!(page, color_scheme: :null)
    assert Page.evaluate!(page, "null") == :null
    assert Page.evaluate!(page, "undefined") == nil
    assert Locator.get_attribute!(Page.locator(page, "button"), "title") == nil
    assert JSON.encode!(%{"z" => :null}) == ~s({"z":"null"})
    assert Page.evaluate!(page, "x => JSON.stringify(x)", %{"z" => :null}) == ~s({"z":null})
    assert Page.evaluate!(page, "x => x.a[0].b === null", %{"a" => [%{"b" => :null}]})
  end

  test "optional arguments", %{page: page} do
    locator = Page.locator(page, "input[name=email]")
    Page.wait_for_load_state!(page, :networkidle)
    Page.wait_for_load_state!(page, timeout: 1_000)
    Expect.to_have_attribute!(locator, "disabled", timeout: 1_000)
  end

  test "promises", %{page: page} do
    promise = Page.wait_for_event(page, :popup)
    Page.get_by_text(page, "Open") |> Locator.click!()
    popup = Promise.await!(promise)
    assert Page.url(popup) == "http://app.test/popup"

    ready = Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) == "ready"))
    Page.evaluate!(page, "() => { console.log('not yet'); console.log('ready') }")
    assert ConsoleMessage.text(Promise.await!(ready)) == "ready"
  end

  test "assertions", %{page: page} do
    Page.get_by_role(page, :button, name: "Save") |> Locator.click!()
    Expect.to_be_visible!(Page.get_by_text(page, "Saved"))
    locator = Page.locator(page, ".status")
    Expect.not_to_have_text!(locator, "Error")
    locator |> Expect.not_() |> Expect.to_have_text!("Error")
    assert {:error, %Playwright.ExpectError{}} = Expect.to_have_text(locator, "Error", timeout: 100)
    assert_raise Playwright.ExpectError, fn -> Expect.to_have_text!(locator, "Error", timeout: 100) end
  end

  test "errors", %{page: page} do
    {:error, %TimeoutError{message: "locator.click: Timeout 100ms exceeded" <> _, log: log}} =
      Page.locator(page, "#missing") |> Locator.click(timeout: 100)

    assert is_list(log)
  end

  test "regular expressions", %{page: page} do
    assert Page.get_by_role(page, :button, name: ~r/submit/i) |> Locator.count!() == 1
    Page.goto!(page, "/dashboard")
    Expect.to_have_url!(page, ~r"/dashboard$")
    assert Page.get_by_text(page, Playwright.RegExp.new("a[^]b", "v")) |> Locator.count!() == 1
    assert_raise ArgumentError, fn -> Page.get_by_text(page, ~r/\Aa/) |> Locator.count() end
  end

  test "evaluate", %{page: page} do
    assert Page.evaluate!(page, "document.title") == "Home"
    assert Page.evaluate!(page, "([a, b]) => a + b", [1, 2]) == 3
    assert Page.locator(page, "button") |> Locator.evaluate!("el => el.textContent") == "Save"

    assert Page.evaluate!(page, "({ at: new Date(0), re: /a/g, n: NaN, i: Infinity, u: undefined, z: null })") ==
             %{
               "at" => ~U[1970-01-01 00:00:00.000Z],
               "re" => %Playwright.RegExp{source: "a", flags: "g"},
               "n" => :nan,
               "i" => :infinity,
               "u" => nil,
               "z" => :null
             }
  end
end
