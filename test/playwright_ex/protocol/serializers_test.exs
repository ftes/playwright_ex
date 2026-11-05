defmodule PlaywrightEx.Protocol.SerializersTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Protocol.Serializers
  alias PlaywrightEx.Protocol.Serializers.JSError

  defp round_trip(value), do: value |> Serializers.serialize_plain_value() |> Serializers.parse_serialized_value(nil)

  test "special values" do
    for value <- [nil, :null, :nan, :infinity, :neg_infinity, -0.0, true, 1, 1.5, "s"] do
      assert round_trip(value) === value
    end
  end

  test "bigint, dates, urls, regexes, errors" do
    assert Serializers.serialize_plain_value(2 ** 60) == %{bi: "1152921504606846976"}
    assert round_trip(2 ** 60) == 2 ** 60
    assert round_trip(~U[2026-11-04 10:00:00.123456Z]) == ~U[2026-11-04 10:00:00.123Z]
    assert round_trip(URI.parse("https://example.com/a?b")) == URI.parse("https://example.com/a?b")
    assert Serializers.serialize_plain_value(~r/a.b/is) == %{r: %{p: "a.b", f: "is"}}
    assert round_trip(~r/a.b/i) == %PlaywrightEx.RegExp{source: "a.b", flags: "i"}
    assert %JSError{name: "TypeError", message: "boom"} = round_trip(%JSError{name: "TypeError", message: "boom"})
    assert %{e: %{n: "ArgumentError", m: "bad"}} = Serializers.serialize_plain_value(%ArgumentError{message: "bad"})
  end

  test "arrays and objects get increasing ids; atom keys become strings" do
    assert Serializers.serialize_plain_value([%{a: [1]}, %{}]) == %{
             a: [%{o: [%{k: "a", v: %{a: [%{n: 1}], id: 3}}], id: 2}, %{o: [], id: 4}],
             id: 1
           }

    assert round_trip(%{a: [1, %{"b" => "c"}]}) == %{"a" => [1, %{"b" => "c"}]}
  end

  test "refs, typed arrays, functions and handles" do
    shared = %{o: [], id: 2}
    assert Serializers.parse_serialized_value(%{a: [shared, %{ref: 2}], id: 1}, nil) == [%{}, %{}]
    assert Serializers.parse_serialized_value(%{a: [%{ref: 1}], id: 1}, nil) == [:circular]
    assert Serializers.parse_serialized_value(%{ta: %{k: "i16", b: <<1, 0, 255, 255>>}}, nil) == [1, -1]
    assert Serializers.parse_serialized_value(%{fn: "f"}, nil) == {:function, "f"}
    assert Serializers.parse_serialized_value(%{h: 1}, [:h0, :h1]) == :h1
    assert_raise RuntimeError, "Unexpected handle", fn -> Serializers.parse_serialized_value(%{h: 0}, nil) end
  end

  test "unexpected values name their position" do
    assert_raise RuntimeError, ~s(Attempting to serialize unexpected value at position "a[0]": {1}), fn ->
      Serializers.serialize_plain_value(%{a: [{1}]})
    end
  end

  defmodule CodeError do
    @moduledoc false
    defexception [:message, :code]
  end

  test "system error messages append a Node-style code" do
    assert Serializers.system_error_message(%CodeError{message: "open failed", code: "ENOENT"}) ==
             "open failed (ENOENT)"

    assert Serializers.system_error_message(%CodeError{message: "ENOENT: open failed", code: "ENOENT"}) ==
             "ENOENT: open failed"

    assert Serializers.system_error_message(%CodeError{message: "m", code: "custom"}) == "m"
    assert Serializers.system_error_message(%ArgumentError{message: "m"}) == "m"
  end
end
