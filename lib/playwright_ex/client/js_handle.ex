defmodule PlaywrightEx.Client.JSHandle do
  @upstream "packages/playwright-core/src/client/jsHandle.ts"
  @moduledoc "Port of `#{@upstream}`: the `JSHandle` constructor and the argument serialization for `evaluate`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Protocol.Serializers

  def from(handle) do
    handle
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_preview, get(this, :_initializer).preview)
    EventEmitter.on(_channel(this), "previewUpdated", fn %{preview: preview} -> put(this, :_preview, preview) end)
    this
  end

  # evaluate, evaluateHandle, getProperty, getProperties, jsonValue, asElement, dispose, toString  -- not ported

  # This function takes care of converting all JSHandles to their channels,
  # so that generic channel serializer converts them to guids.
  def serialize_argument(arg, register_callback \\ nil) do
    # `handles.push(...)` from the serializer callback: an accumulator in the process dictionary.
    handles = make_ref()
    Process.put(handles, [])

    push_handle = fn channel ->
      Process.put(handles, Process.get(handles) ++ [channel])
      length(Process.get(handles)) - 1
    end

    value =
      Serializers.serialize_value(arg, fn value ->
        cond do
          is_js_handle(value) -> %{h: push_handle.(value)}
          is_function(value) and register_callback != nil -> %{fn: register_callback.(value)}
          true -> %{fallThrough: value}
        end
      end)

    %{value: value, handles: Process.delete(handles)}
  end

  # serializeArgumentWithCallbacks  -- not ported: exposeFunctions (Page._exposeEvaluateCallback)

  def parse_result(value) do
    Serializers.parse_serialized_value(value, nil)
  end

  # assertMaxArguments  -- not ported: Elixir arities are fixed

  def assert_evaluate_options(options) do
    if options != nil and not is_map(options),
      do: raise("Too many arguments. If you need to pass more than 1 argument to the function wrap them in an object.")
  end

  # `value instanceof JSHandle` (ElementHandle extends JSHandle)
  defp is_js_handle(value),
    do: ChannelOwner.is_channel_owner(value) and get(value, :_type) in ["JSHandle", "ElementHandle"]
end
