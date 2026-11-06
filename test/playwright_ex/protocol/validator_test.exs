defmodule PlaywrightEx.Protocol.ValidatorTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Protocol.Metainfo
  alias PlaywrightEx.Protocol.Validator
  alias PlaywrightEx.Protocol.ValidatorPrimitives.ValidationError

  @objects %{"browser-type@1" => :chromium, "browser-type@2" => :firefox}

  defp from_wire do
    %{
      binary: "fromBase64",
      tChannelImpl: fn _names, %{"guid" => guid}, _path, _context -> Map.fetch!(@objects, guid) end
    }
  end

  defp to_wire do
    %{binary: "toBase64", tChannelImpl: fn _names, arg, _path, _context -> %{guid: arg} end}
  end

  test "from wire: known keys become atoms, channels become objects, undefined is dropped" do
    validator = Validator.find_validator("Playwright", "", "Initializer")

    wire = %{
      "chromium" => %{"guid" => "browser-type@1"},
      "firefox" => %{"guid" => "browser-type@2"},
      "webkit" => %{"guid" => "browser-type@1"},
      "android" => %{"guid" => "browser-type@1"},
      "electron" => %{"guid" => "browser-type@1"},
      "unknown" => 1
    }

    assert %{chromium: :chromium, firefox: :firefox} = result = validator.(wire, "", from_wire())
    refute Map.has_key?(result, :utils)
    refute Map.has_key?(result, :unknown)
  end

  test "binary: base64 on the wire, raw binaries in the client" do
    params = Validator.find_validator("WritableStream", "write", "Params")
    assert params.(%{binary: <<0, 255>>}, "", to_wire()) == %{binary: "AP8="}

    result = Validator.find_validator("Stream", "read", "Result")
    assert result.(%{"binary" => "AP8="}, "", from_wire()) == %{binary: <<0, 255>>}
  end

  test "derived classes reuse their ancestor's schemes" do
    assert Validator.scheme("ElementHandleEvaluateExpressionParams") == {:type, "JSHandleEvaluateExpressionParams"}
    assert Validator.maybe_find_validator("ElementHandle", "evaluateExpression", "Params")
  end

  test "commands without parameters accept undefined" do
    assert Validator.find_validator("Browser", "close", "Result").(nil, "", from_wire()) == nil
    assert Validator.maybe_find_validator("Browser", "noSuchMethod", "Params") == nil

    assert_raise ValidationError, "Unknown scheme for Result: Browser.noSuchMethod", fn ->
      Validator.find_validator("Browser", "noSuchMethod", "Result")
    end
  end

  test "errors name the path" do
    params = Validator.find_validator("Frame", "goto", "Params")
    assert_raise ValidationError, "url: expected string, got undefined", fn -> params.(%{}, "", to_wire()) end

    assert_raise ValidationError, ~r/^waitUntil: expected one of \(load\|/, fn ->
      params.(%{url: "x", waitUntil: "nope"}, "", to_wire())
    end

    assert_raise ValidationError, "referer: expected string, got number", fn ->
      params.(%{url: "x", referer: 1}, "", to_wire())
    end
  end

  test "metainfo" do
    assert Metainfo.get_metainfo(%{type: "Root", method: "initialize"}) == %{internal: true}

    assert %{title: "Navigate", subtitle: "{url}", renderParams: ["url"], slowMo: true} =
             Metainfo.get_metainfo(%{type: "Frame", method: "goto"})

    assert Metainfo.get_metainfo(%{type: "Frame", method: "nope"}) == nil
  end
end
