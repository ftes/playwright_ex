# upstream: packages/playwright-core/src/client/jsHandle.ts (module-level helpers only)
defmodule PlaywrightJS.Client.JSHandle do
  alias PlaywrightJS.Protocol.Serializers

  # upstream: jsHandle.ts:98
  def serialize_argument(arg, _register_callback \\ nil) do
    handles = []
    # const pushHandle = ...; JSHandle / function args  -- not ported
    value = Serializers.serialize_value(arg, fn value -> %{fallThrough: value} end)
    %{value: value, handles: handles}
  end

  # upstream: jsHandle.ts (parseResult)
  def parse_result(value) do
    Serializers.parse_serialized_value(value, nil)
  end
end
