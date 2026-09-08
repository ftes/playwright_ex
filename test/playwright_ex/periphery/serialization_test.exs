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

    test "deserializes protocol regex values and ignores unsupported JS-only flags" do
      value = %{r: %{p: "abc", f: "gimsyu"}}

      assert %Regex{source: "abc"} = regex = Serialization.deserialize_arg(value)
      assert :caseless in regex.opts
      assert :multiline in regex.opts
      assert :dotall in regex.opts
      assert :unicode in regex.opts
    end

    test "round-trips regex values semantically" do
      for value <- [~r/abc/, ~r/abc/imsu] do
        serialized = Serialization.serialize_arg(value)
        deserialized = Serialization.deserialize_arg(serialized.value)

        assert %Regex{} = deserialized
        assert deserialized.source == value.source

        assert Serialization.regex_flags_for_protocol(deserialized.opts) ==
                 Serialization.regex_flags_for_protocol(value.opts)
      end
    end

    test "round-trips Playwright 1.63 date, URL, and bigint values" do
      datetime = ~U[2026-09-08 12:34:56Z]

      for value <- [datetime, URI.parse("https://example.com/a?b=c"), 9_007_199_254_740_992] do
        serialized = Serialization.serialize_arg(value)
        assert Serialization.deserialize_arg(serialized.value) == value
      end
    end

    test "deserializes special numeric and typed-array values" do
      assert :nan = Serialization.deserialize_arg(%{v: "NaN"})
      assert :infinity = Serialization.deserialize_arg(%{v: "Infinity"})
      assert :negative_infinity = Serialization.deserialize_arg(%{v: "-Infinity"})
      assert :negative_zero = Serialization.deserialize_arg(%{v: "-0"})

      assert %{type: :uint8, data: <<0, 1, 255>>} =
               Serialization.deserialize_arg(%{ta: %{k: "ui8", b: Base.encode64(<<0, 1, 255>>)}})

      for value <- [:nan, :infinity, :negative_infinity, :negative_zero, %{type: :uint8, data: <<0, 1, 255>>}] do
        serialized = Serialization.serialize_arg(value)
        assert Serialization.deserialize_arg(serialized.value) == value
      end
    end

    test "deserializes JavaScript errors, handles, and functions" do
      assert %{name: "TypeError", message: "bad", stack: "stack"} =
               Serialization.deserialize_arg(%{e: %{n: "TypeError", m: "bad", s: "stack"}})

      assert {:handle, 2} = Serialization.deserialize_arg(%{h: 2})
      assert {:function, "fn@1"} = Serialization.deserialize_arg(%{fn: "fn@1"})

      for value <- [{:handle, 2}, {:function, "fn@1"}] do
        serialized = Serialization.serialize_arg(value)
        assert Serialization.deserialize_arg(serialized.value) == value
      end
    end

    test "resolves non-cyclic references and reports cyclic references" do
      assert ["value", "value"] =
               Serialization.deserialize_arg(%{a: [%{s: "value", id: 1}, %{ref: 1}]})

      assert [{:circular_reference, 1}] =
               Serialization.deserialize_arg(%{a: [%{ref: 1}], id: 1})
    end
  end

  describe "wire key conversion" do
    test "preserves arbitrary JSON keys and does not intern unknown protocol keys" do
      unknown = "unknown_#{System.unique_integer([:positive])}"
      nested_unknown = "nested_#{System.unique_integer([:positive])}"

      assert %{^unknown => %{^nested_unknown => true}} =
               Serialization.deep_key_underscore(%{unknown => %{nested_unknown => true}})

      refute is_atom(hd(Map.keys(Serialization.deep_key_underscore(%{unknown => true}))))

      assert %{"alreadyCamel" => %{"snake_key" => true}} =
               Serialization.deep_key_camelize(%{"alreadyCamel" => %{"snake_key" => true}})
    end

    test "preserves expression arguments and structured snapshots as opaque JSON" do
      assert %{"expressionArg" => %{:snake_key => %{"nested_key" => true}}} =
               Serialization.deep_key_camelize(%{expression_arg: %{snake_key: %{"nested_key" => true}}})

      assert %{snapshot: %{"role_key" => %{"nested_key" => true}}} =
               Serialization.deep_key_underscore(%{"snapshot" => %{"role_key" => %{"nested_key" => true}}})
    end

    test "preserves IndexedDB key and value payloads" do
      payload = %{
        "keyEncoded" => "encoded-key",
        "valueEncoded" => "encoded-value",
        "key" => %{"user_key" => 1},
        "value" => %{"user_value" => 2}
      }

      assert %{
               key_encoded: "encoded-key",
               value_encoded: "encoded-value",
               key: %{"user_key" => 1},
               value: %{"user_value" => 2}
             } = Serialization.deep_key_underscore(payload)
    end
  end

  test "extracts messages from serialized errors" do
    assert "boom" = Serialization.serialized_error_message(%{error: %{message: "boom"}})
    assert "boom" = Serialization.serialized_error_message(%{value: %{s: "boom"}})
  end

  describe "regex_flags_for_protocol/1" do
    test "maps Elixir regex opts to JS protocol flags" do
      assert Serialization.regex_flags_for_protocol([:caseless, :multiline, :dotall, :unicode, :ucp]) == "imsu"
    end
  end
end
