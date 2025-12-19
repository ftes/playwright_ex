defmodule PlaywrightEx.SerializationTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Serialization

  describe "serialize_arg/1" do
    test "returns expected structure with handles" do
      result = Serialization.serialize_arg("test")

      assert %{value: _, handles: []} = result
    end
  end

  describe "serialize_arg/1 and deserialize_arg/1 round-trip" do
    @test_values [
      nil,
      true,
      false,
      0,
      42,
      -17,
      3.14,
      -2.5,
      "",
      "hello",
      "hello world",
      "with \"quotes\" and 'apostrophes'",
      "unicode: ὁ χριστός",
      [],
      [1, 2, 3],
      ["a", "b", "c"],
      [true, false, nil],
      [1, "two", 3.0, nil, true],
      [[1, 2], [3, 4]],
      %{},
      %{"key" => "value"},
      %{"a" => 1, "b" => 2},
      %{"nested" => %{"deep" => "value"}},
      %{"mixed" => [1, "two", %{"three" => 3}]},
      %{"bool" => true, "nil" => nil, "num" => 42, "str" => "hello"}
    ]

    for value <- @test_values do
      test "round-trips #{inspect(value)}" do
        value = unquote(Macro.escape(value))

        serialized = Serialization.serialize_arg(value)
        deserialized = Serialization.deserialize_arg(serialized.value)

        assert deserialized == value
      end
    end

    test "converts atoms to strings" do
      value = :some_atom

      serialized = Serialization.serialize_arg(value)
      deserialized = Serialization.deserialize_arg(serialized.value)

      # Atoms become strings after round-trip
      assert deserialized == "some_atom"
    end

    test "converts atom keys to string keys in maps" do
      value = %{foo: "bar", baz: 123}

      serialized = Serialization.serialize_arg(value)
      deserialized = Serialization.deserialize_arg(serialized.value)

      # Atom keys become string keys after round-trip
      assert deserialized == %{"foo" => "bar", "baz" => 123}
    end
  end
end
