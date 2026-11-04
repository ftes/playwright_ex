defmodule PlaywrightEx.Runtime.FacadeTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Runtime.Facade

  @schema {:object,
           %{
             timeout: {:timeout, nil},
             color_scheme: {:colorScheme, {:enum, %{light: "light", no_preference: "no-preference"}}},
             env: {:env, nil},
             viewport: {:viewport, {:object, %{width: {:width, nil}, height: {:height, nil}}}},
             cookies: {:cookies, {:array, {:object, %{same_site: {:sameSite, {:enum, %{lax: "Lax"}}}}}}},
             storage_state: {:storageState, {:union, [{:object, %{origins: {:origins, nil}}}]}}
           }}

  test "converts keys and nested objects to JS names" do
    assert Facade.options!(
             [color_scheme: :no_preference, viewport: [width: 1, height: 2], env: %{"FOO_BAR" => "1"}],
             @schema,
             "x.y"
           ) == %{colorScheme: "no-preference", viewport: %{width: 1, height: 2}, env: %{"FOO_BAR" => "1"}}
  end

  test "accepts maps, JS names and wire strings, so returned values round-trip" do
    assert Facade.options!(%{colorScheme: "light", cookies: [%{sameSite: "Lax"}, [same_site: :lax]]}, @schema, "x.y") ==
             %{colorScheme: "light", cookies: [%{sameSite: "Lax"}, %{sameSite: "Lax"}]}
  end

  test "unions convert the matching shape and pass the others through" do
    assert Facade.options!([storage_state: "state.json"], @schema, "x.y") == %{storageState: "state.json"}
    assert Facade.options!([storage_state: [origins: []]], @schema, "x.y") == %{storageState: %{origins: []}}
  end

  test "timeout: :infinity is 0, :null and nil pass through" do
    assert Facade.options!([timeout: :infinity, color_scheme: :null, viewport: nil], @schema, "x.y") ==
             %{timeout: 0, colorScheme: :null, viewport: nil}
  end

  test "rejects unknown options and enum values" do
    assert_raise ArgumentError, ~r/^x\.y: unknown option :colour_scheme, expected one of :color_scheme, /, fn ->
      Facade.options!([colour_scheme: :light], @schema, "x.y")
    end

    assert_raise ArgumentError,
                 "x.y: invalid value :dark for :color_scheme, expected one of :light, :no_preference",
                 fn ->
                   Facade.options!([color_scheme: :dark], @schema, "x.y")
                 end

    assert_raise ArgumentError, ~r/^x\.y: unknown option :viewport\.depth/, fn ->
      Facade.options!([viewport: [depth: 1]], @schema, "x.y")
    end
  end

  test "events" do
    events = %{page_error: "pageerror"}
    assert Facade.event!(:page_error, events, "page.on") == "pageerror"
    assert Facade.event!("pageerror", events, "page.on") == "pageerror"
    assert_raise ArgumentError, ~r/unknown event :pageerror/, fn -> Facade.event!(:pageerror, events, "page.on") end
  end
end
