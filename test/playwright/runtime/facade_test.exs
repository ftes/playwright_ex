defmodule Playwright.Runtime.FacadeTest do
  use ExUnit.Case, async: true

  alias Playwright.Runtime.Facade
  alias Playwright.Runtime.ProtocolType

  @schema {:object,
           %{
             timeout: {:timeout, nil},
             color_scheme: {:colorScheme, {:enum, %{light: "light", no_preference: "no-preference"}}},
             env: {:env, nil},
             viewport: {:viewport, {:fields, %{width: nil, height: nil}}},
             cookies: {:cookies, {:array, {:fields, %{sameSite: nil}}}},
             storage_state: {:storageState, {:union, [{:fields, %{origins: nil}}]}}
           }}

  test "converts option keys and enums to JS, nested objects pass as they are" do
    assert Facade.options!(
             [color_scheme: :no_preference, viewport: %{width: 1, height: 2}, env: %{"FOO_BAR" => "1"}],
             @schema,
             "x.y"
           ) == %{colorScheme: "no-preference", viewport: %{width: 1, height: 2}, env: %{"FOO_BAR" => "1"}}
  end

  test "accepts maps and wire strings, nested objects have JS keys so returned values round-trip" do
    assert Facade.options!(%{color_scheme: "light", cookies: [%{sameSite: "Lax"}]}, @schema, "x.y") ==
             %{colorScheme: "light", cookies: [%{sameSite: "Lax"}]}
  end

  test "unions check the matching shape and pass the others through" do
    assert Facade.options!([storage_state: "state.json"], @schema, "x.y") == %{storageState: "state.json"}
    assert Facade.options!([storage_state: %{origins: []}], @schema, "x.y") == %{storageState: %{origins: []}}
  end

  test "timeout: :infinity is 0, :null and nil pass through" do
    assert Facade.options!([timeout: :infinity, color_scheme: :null, viewport: nil], @schema, "x.y") ==
             %{timeout: 0, colorScheme: :null, viewport: nil}
  end

  test "APIRequest.new_context's storage state credentials pass unchecked, as its validator drops them" do
    state = %{cookies: [], origins: [], credentials: [%{anything: 1}]}
    type = Playwright.APIRequest.__options_type__(:new_context)
    assert %{storageState: ^state} = Facade.options!([storage_state: state], type, "apiRequest.newContext")

    # A browser context's are the protocol's.
    assert_raise ArgumentError, ~r/unknown field storage_state\.credentials\[0\]\.anything, /, fn ->
      Facade.options!([storage_state: state], Playwright.Browser.__options_type__(:new_context), "browser.newContext")
    end
  end

  test "rejects unknown options, fields and enum values" do
    assert_raise ArgumentError, ~r/^x\.y: unknown option colour_scheme, expected one of color_scheme, /, fn ->
      Facade.options!([colour_scheme: :light], @schema, "x.y")
    end

    assert_raise ArgumentError, ~r/^x\.y: unknown option colorScheme, /, fn ->
      Facade.options!([colorScheme: "light"], @schema, "x.y")
    end

    assert_raise ArgumentError,
                 "x.y: invalid value :dark for color_scheme, expected one of :light, :no_preference",
                 fn ->
                   Facade.options!([color_scheme: :dark], @schema, "x.y")
                 end

    assert_raise ArgumentError, "x.y: unknown field viewport.depth, expected one of height, width", fn ->
      Facade.options!([viewport: %{depth: 1}], @schema, "x.y")
    end

    assert_raise ArgumentError, "x.y: unknown field cookies[1].same_site, expected one of sameSite", fn ->
      Facade.options!([cookies: [%{sameSite: "Lax"}, %{same_site: "Lax"}]], @schema, "x.y")
    end
  end

  test "positional arguments: errors name the argument, with the index in an array" do
    fields = {:fields, %{name: nil, origin: {:fields, %{url: nil}}}}
    assert Facade.arg!([%{name: "a"}, "b"], {:union, [{:array, fields}]}, "x.y", :items) == [%{name: "a"}, "b"]

    assert_raise ArgumentError, "x.y: unknown field cookies[0].http_only, expected one of name, origin", fn ->
      Facade.arg!([%{http_only: true}], {:array, fields}, "x.y", :cookies)
    end

    assert_raise ArgumentError, "x.y: unknown field item.origin.uri, expected one of url", fn ->
      Facade.arg!(%{origin: %{uri: "u"}}, fields, "x.y", :item)
    end

    assert_raise ArgumentError, "x.y: invalid value :dark for scheme, expected one of :light", fn ->
      Facade.arg!(:dark, {:enum, %{light: "light"}}, "x.y", :scheme)
    end
  end

  @result_schema {:object, %{private_key: {:privateKey, nil}, sign_count: {:signCount, nil}}}

  test "result options: a result with JS keys is the options, its fields that are no options are ignored" do
    known = %{privateKey: "k", signCount: 3, rpId: "example.com"}
    assert Facade.result_options!(known, @result_schema, [:rpId], "x.y") == %{privateKey: "k", signCount: 3}
    assert Facade.result_options!([private_key: "k"], @result_schema, [:rpId], "x.y") == %{privateKey: "k"}
    assert Facade.result_options!(%{sign_count: 1}, @result_schema, [:rpId], "x.y") == %{signCount: 1}
  end

  test "result options: unknown keys still raise" do
    assert_raise ArgumentError, ~r/^x\.y: unknown option bogus, /, fn ->
      Facade.result_options!(%{privateKey: "k", bogus: 1}, @result_schema, [:rpId], "x.y")
    end

    assert_raise ArgumentError, ~r/^x\.y: unknown option rpId, /, fn ->
      Facade.result_options!([rpId: "example.com"], @result_schema, [:rpId], "x.y")
    end

    # The generated facade checks before calling the client.
    assert_raise ArgumentError, ~r/^credentials\.create: unknown option bogus, /, fn ->
      Playwright.Credentials.create!(%Playwright.Credentials{}, "example.com", %{id: "a", bogus: 1})
    end
  end

  test "objects passed on to the protocol have the keys of its params, as atoms or strings" do
    type = ProtocolType.of("BrowserContextAddCookiesParams", :cookies)
    cookies = [%{"name" => "a", "httpOnly" => true}, %{name: "b", _crHasCrossSiteAncestor: false}]
    assert Facade.arg!(cookies, type, "x.y", :cookies) == cookies

    assert_raise ArgumentError,
                 ~r/^x\.y: unknown field cookies\[0\]\."http_only", expected one of "_crHasCrossSiteAncestor", "domain", /,
                 fn ->
                   Facade.arg!([%{"name" => "a", "http_only" => true}], type, "x.y", :cookies)
                 end

    # Other nested objects: atom keys, as the client reads them.
    assert_raise ArgumentError, ~s(x.y: unknown field cookies[0]."name", expected one of httpOnly, name), fn ->
      Facade.arg!([%{"name" => "a"}], {:array, {:fields, %{name: nil, httpOnly: nil}}}, "x.y", :cookies)
    end
  end

  test "a protocol type nested in itself passes unchecked where it recurs" do
    # `SerializedValue` holds `SerializedValue`s (`a`, `o[].v`).
    assert {:protocol, %{value: {:protocol, value, _}}, _} = ProtocolType.of("JSHandleEvaluateExpressionParams", :arg)
    assert {:array, {:protocol, %{v: nil}, _}} = value.o
    assert value.a == nil
  end

  test "keys that need quoting are quoted, so a key with a dot is no path" do
    assert_raise ArgumentError, ~s(x.y: unknown field viewport.:"proxy.server", expected one of height, width), fn ->
      Facade.options!([viewport: %{"proxy.server": 1}], @schema, "x.y")
    end

    assert_raise ArgumentError, ~r/^x\.y: unknown option :"proxy\.server", expected one of color_scheme, /, fn ->
      Facade.options!(["proxy.server": 1], @schema, "x.y")
    end

    # Bare where an atom literal needs no quotes.
    assert_raise ArgumentError, ~r/^x\.y: unknown option headless\?, /, fn ->
      Facade.options!([headless?: true], @schema, "x.y")
    end
  end

  # The generated facade checks every object argument before calling the client.
  test "generated: object arguments in lists, unions and storage states" do
    context = %Playwright.BrowserContext{}
    locator = %Playwright.Locator{}

    assert_raise ArgumentError, ~r/^browserContext\.addCookies: unknown field cookies\[0\]\.http_only, /, fn ->
      Playwright.BrowserContext.add_cookies(context, [%{name: "a", value: "b", url: "u", http_only: true}])
    end

    assert_raise ArgumentError, ~r/^apiRequestContext\.addCookies: unknown field cookies\[0\]\.same_site, /, fn ->
      Playwright.APIRequestContext.add_cookies(%Playwright.APIRequestContext{}, [
        %{name: "a", value: "b", same_site: "Lax"}
      ])
    end

    assert_raise ArgumentError,
                 ~r/^browserContext\.setStorageState: unknown field storage_state\.origins\[0\]\.local_storage, /,
                 fn ->
                   Playwright.BrowserContext.set_storage_state(context, %{origins: [%{origin: "o", local_storage: []}]})
                 end

    assert_raise ArgumentError, ~r/^browser\.newContext: unknown field storage_state\.cookies\[0\]\.http_only, /, fn ->
      Playwright.Browser.new_context(%Playwright.Browser{}, storage_state: %{cookies: [%{http_only: true}]})
    end

    # Any storage state, as JS takes one; its credentials unchecked, as the validator drops them.
    assert_raise ArgumentError,
                 ~r/^apiRequest\.newContext: unknown field storage_state\.cookies\[0\]\.http_only, /,
                 fn ->
                   Playwright.APIRequest.new_context(%Playwright.APIRequest{},
                     storage_state: %{cookies: [%{http_only: true}]}
                   )
                 end

    # Object | Array<Object> unions: one object, or one in a list.
    assert_raise ArgumentError, ~r/^locator\.selectOption: unknown field values\[1\]\.val, /, fn ->
      Playwright.Locator.select_option(locator, ["a", %{val: "b"}])
    end

    assert_raise ArgumentError, ~r/^locator\.setInputFiles: unknown field files\.mime_type, /, fn ->
      Playwright.Locator.set_input_files(locator, %{name: "a", mime_type: "t", buffer: "b"})
    end

    # Nested in an option object.
    assert_raise ArgumentError, ~r/^locator\.drop: unknown field payload\.files\[0\]\.mime_type, /, fn ->
      Playwright.Locator.drop(locator, %{files: [%{name: "a", mime_type: "t", buffer: "b"}]})
    end

    # A dictionary's keys are data, its values are checked: a multipart file.
    request = %Playwright.APIRequestContext{}

    assert_raise ArgumentError,
                 ~s(apiRequestContext.post: unknown field multipart."file".mime_type, expected one of buffer, mimeType, name),
                 fn ->
                   Playwright.APIRequestContext.post(request, "/",
                     multipart: %{"name" => "x", "file" => %{name: "a", mime_type: "t", buffer: "b"}}
                   )
                 end

    # The FormData form: a keyword list, names repeated.
    assert_raise ArgumentError, ~r/^apiRequestContext\.post: unknown field multipart\.file\.mime_type, /, fn ->
      Playwright.APIRequestContext.post(request, "/",
        multipart: [
          name: "x",
          file: %{name: "a", mimeType: "t", buffer: "b"},
          file: %{name: "b", mime_type: "t", buffer: "b"}
        ]
      )
    end

    # A dictionary in a union: a map is checked as one.
    assert_raise ArgumentError, ~r/^x\.y: unknown field form\.f\.mime_type, /, fn ->
      Facade.arg!(
        %{f: %{mime_type: "t"}},
        {:union, [{:enum, %{a: "a"}}, {:dictionary, {:fields, %{mimeType: nil}}}]},
        "x.y",
        :form
      )
    end
  end

  test "events" do
    events = %{page_error: "pageerror"}
    assert Facade.event!(:page_error, events, "page.on") == "pageerror"
    assert Facade.event!("pageerror", events, "page.on") == "pageerror"
    assert_raise ArgumentError, ~r/unknown event :pageerror/, fn -> Facade.event!(:pageerror, events, "page.on") end
  end

  test "tuple forms return the errors upstream rejects with, and raise anything else" do
    for error <- [
          %Playwright.TimeoutError{message: "x"},
          %Playwright.TargetClosedError{},
          %RuntimeError{message: "Route is already handled!"},
          %File.Error{reason: :enoent, path: "x", action: "read file"}
        ] do
      assert Facade.async(nil, fn -> raise error end) == {:error, error}
      assert Facade.async_void(nil, fn -> raise error end) == {:error, error}
    end

    # Bugs: values the type checker doesn't see at compile time.
    {map, number} = Process.get(:not_set, {%{}, 1})
    assert_raise KeyError, fn -> Facade.async(nil, fn -> Map.fetch!(map, :x) end) end
    assert_raise FunctionClauseError, fn -> Facade.async_void(nil, fn -> String.trim(number) end) end
  end

  test "a matcher's message: option points to Expect.message/2, for the matcher as called" do
    locator = %Playwright.Locator{}

    assert_raise ArgumentError,
                 ~r/^expect\.toBeVisible: unknown option message, expected one of .*\. A matcher's custom message goes with Playwright\.Expect\.message\/2 \(JS expect\(actual, message\)\), for Expect\.to_be_visible!: x \|> Expect\.message\("\.\.\."\) \|> Expect\.to_be_visible!\(\.\.\.\)$/,
                 fn -> Playwright.Expect.to_be_visible!(locator, message: "visible") end

    assert_raise ArgumentError,
                 ~r/for Expect\.to_have_text: x \|> Expect\.message\("\.\.\."\) \|> Expect\.to_have_text\(\.\.\.\)$/,
                 fn ->
                   Playwright.Expect.to_have_text(locator, "Hi", message: "text")
                 end

    # Elsewhere, no hint.
    assert_raise ArgumentError, ~r/^x\.y: unknown option message, expected one of [^.]*$/, fn ->
      Facade.options!([message: "m"], @schema, "x.y")
    end
  end

  test "a failed bang matcher raises the ExpectError" do
    error = %Playwright.ExpectError{message: "Expect failed"}
    assert Facade.matcher(fn -> raise error end) == {:error, error}
    assert_raise Playwright.ExpectError, "Expect failed", fn -> Facade.matcher!(fn -> raise error end) end
  end

  test "expect: when the action raises, the wait's later result leaves no message" do
    test = self()

    wait = fn ->
      send(test, {:waiting, self()})
      Playwright.Runtime.Invocation.yield()

      receive do
        :go -> :value
      end
    end

    for expect <- [&Facade.expect/3, &Facade.expect!/3] do
      assert_raise RuntimeError, "boom", fn -> expect.(nil, wait, fn -> raise "boom" end) end
      assert_receive {:waiting, pid}
      ref = Process.monitor(pid)
      send(pid, :go)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      refute_received {:pw, _, _}
    end
  end

  test "a handle of another class as the receiver fails in the facade function, naming it" do
    # Not known at compile time, as in a user's helper.
    locator = Process.get(:not_set, %Playwright.Locator{_selector: "internal:testid=[data-testid=\"x\"s]"})

    {e, stacktrace} =
      try do
        Playwright.Page.get_by_test_id(locator, "y")
      rescue
        e -> {e, __STACKTRACE__}
      end

    assert %FunctionClauseError{module: Playwright.Page, function: :get_by_test_id, arity: 2} = e
    {blamed, _} = Exception.blame(:error, e, stacktrace)
    message = Exception.message(blamed)
    assert message =~ "#Playwright.Locator<"
    assert message =~ "def get_by_test_id(-%Playwright.Page{} = page-, test_id)"

    # A clause for a function in place of the options matches it too: the error has the
    # arguments as given, not as that clause passes them on (`predicate: predicate`).
    predicate = fn _ -> true end

    {e, stacktrace} =
      try do
        Playwright.Page.wait_for_event(locator, :load, predicate)
      rescue
        e -> {e, __STACKTRACE__}
      end

    assert {%FunctionClauseError{function: :wait_for_event, args: args}, _} = Exception.blame(:error, e, stacktrace)
    assert args == [locator, :load, predicate]
  end
end
