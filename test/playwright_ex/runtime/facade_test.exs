defmodule PlaywrightEx.Runtime.FacadeTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Runtime.Facade

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

  test "rejects unknown options, fields and enum values" do
    assert_raise ArgumentError, ~r/^x\.y: unknown option :colour_scheme, expected one of :color_scheme, /, fn ->
      Facade.options!([colour_scheme: :light], @schema, "x.y")
    end

    assert_raise ArgumentError, ~r/^x\.y: unknown option :colorScheme, /, fn ->
      Facade.options!([colorScheme: "light"], @schema, "x.y")
    end

    assert_raise ArgumentError,
                 "x.y: invalid value :dark for :color_scheme, expected one of :light, :no_preference",
                 fn ->
                   Facade.options!([color_scheme: :dark], @schema, "x.y")
                 end

    assert_raise ArgumentError, "x.y: unknown field :viewport.depth, expected one of :height, :width", fn ->
      Facade.options!([viewport: %{depth: 1}], @schema, "x.y")
    end

    assert_raise ArgumentError, ~r/^x\.y: unknown field :cookies\.same_site/, fn ->
      Facade.options!([cookies: [%{same_site: "Lax"}]], @schema, "x.y")
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
    assert_raise ArgumentError, ~r/^x\.y: unknown option :bogus, /, fn ->
      Facade.result_options!(%{privateKey: "k", bogus: 1}, @result_schema, [:rpId], "x.y")
    end

    assert_raise ArgumentError, ~r/^x\.y: unknown option :rpId, /, fn ->
      Facade.result_options!([rpId: "example.com"], @result_schema, [:rpId], "x.y")
    end

    # The generated facade checks before calling the client.
    assert_raise ArgumentError, ~r/^credentials\.create: unknown option :bogus, /, fn ->
      PlaywrightEx.Credentials.create!(%PlaywrightEx.Credentials{}, "example.com", %{id: "a", bogus: 1})
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
          %PlaywrightEx.TimeoutError{message: "x"},
          %PlaywrightEx.TargetClosedError{},
          %RuntimeError{message: "Route is already handled!"},
          %File.Error{reason: :enoent, path: "x", action: "read file"}
        ] do
      assert Facade.async(nil, nil, fn -> raise error end) == {:error, error}
      assert Facade.async_void(nil, nil, fn -> raise error end) == {:error, error}
    end

    # Bugs: values the type checker doesn't see at compile time.
    {map, number} = Process.get(:not_set, {%{}, 1})
    assert_raise KeyError, fn -> Facade.async(nil, nil, fn -> Map.fetch!(map, :x) end) end
    assert_raise FunctionClauseError, fn -> Facade.async_void(nil, nil, fn -> String.trim(number) end) end
  end

  test "a failed bang matcher raises the ExpectError" do
    error = %PlaywrightEx.ExpectError{message: "Expect failed"}
    assert Facade.matcher(nil, fn -> raise error end) == {:error, error}
    assert_raise PlaywrightEx.ExpectError, "Expect failed", fn -> Facade.matcher!(nil, fn -> raise error end) end
  end
end
