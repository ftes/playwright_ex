defmodule PlaywrightEx.Client.JSHandle do
  @upstream "packages/playwright-core/src/client/jsHandle.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  `ElementHandle extends JSHandle`: `PlaywrightEx.Client.ElementHandle` is its own struct and
  module; the methods here take either handle. `asElement`, the one method ElementHandle
  overrides, dispatches on the struct. `toString` is also `String.Chars` (`"\#{handle}"`).
  """
  use PlaywrightEx.Client.ChannelOwner, struct: PlaywrightEx.JSHandle

  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Isomorphic.UtilityScriptSerializers
  alias PlaywrightEx.Protocol.Serializers

  def from(handle) do
    handle
  end

  # `module` is the subclass for `super(...)` in ElementHandle, as in ChannelOwner.new/5.
  def new(module \\ __MODULE__, parent, type, guid, initializer) do
    this = ChannelOwner.new(module, parent, type, guid, initializer)
    put(this, :_preview, get(this, :_initializer).preview)
    EventEmitter.on(_channel(this), "previewUpdated", fn %{preview: preview} -> put(this, :_preview, preview) end)
    this
  end

  def evaluate(this, page_function, arg \\ nil, options \\ nil) do
    assert_evaluate_options(options)

    serialized_arg =
      if options[:exposeFunctions],
        do: serialize_argument_with_callbacks(this, _parent_of_type(this, "Page"), arg),
        else: serialize_argument(arg)

    # isFunction: typeof pageFunction === 'function'  -- not ported: page functions are JS source (PLAN)
    result =
      channel_call(
        this,
        :evaluateExpression,
        %{expression: page_function, arg: serialized_arg},
        TimeoutSettings.k_no_timeout()
      )

    parse_result(result.value)
  end

  def evaluate_handle(this, page_function, arg \\ nil, options \\ nil) do
    assert_evaluate_options(options)

    serialized_arg =
      if options[:exposeFunctions],
        do: serialize_argument_with_callbacks(this, _parent_of_type(this, "Page"), arg),
        else: serialize_argument(arg)

    # isFunction: typeof pageFunction === 'function'  -- not ported: page functions are JS source (PLAN)
    result =
      channel_call(
        this,
        :evaluateExpressionHandle,
        %{expression: page_function, arg: serialized_arg},
        TimeoutSettings.k_no_timeout()
      )

    from(result.handle)
  end

  def get_property(this, property_name) do
    result = channel_call(this, :getProperty, %{name: property_name}, TimeoutSettings.k_no_timeout())
    from(result.handle)
  end

  # `Map<string, JSHandle>` is a map.
  def get_properties(this) do
    for %{name: name, value: value} <-
          channel_call(this, :getPropertyList, %{}, TimeoutSettings.k_no_timeout()).properties,
        into: %{},
        do: {name, from(value)}
  end

  def json_value(this) do
    parse_result(channel_call(this, :jsonValue, %{}, TimeoutSettings.k_no_timeout()).value)
  end

  # ElementHandle overrides asElement: dispatch on the struct.
  def as_element(%PlaywrightEx.JSHandle{}) do
    nil
  end

  def as_element(this), do: impl(this).as_element(this)

  # [Symbol.asyncDispose]  -- not ported: await using

  def dispose(this) do
    try do
      channel_call(this, :dispose, %{}, TimeoutSettings.k_no_timeout())
    rescue
      e ->
        if Errors.is_target_closed_error(e),
          do: nil,
          else: reraise(e, __STACKTRACE__)
    end

    nil
  end

  def to_string(this) do
    get(this, :_preview)
  end

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

  def serialize_argument_with_callbacks(owner, page, arg) do
    ChannelOwner._wrap_api_call(
      owner,
      fn _ ->
        # `exposePromises.push(...)` from the serializer callback: an accumulator in the process dictionary.
        expose_promises = make_ref()
        Process.put(expose_promises, [])

        serialized =
          serialize_argument(arg, fn callback ->
            if !page, do: raise("Passing a function is not supported as an argument here")
            name = UtilityScriptSerializers.k_function_binding_prefix() <> ClientHelper.create_guid()
            promise = Promise.async(fn -> Page._expose_evaluate_callback(page, name, callback) end)
            Process.put(expose_promises, Process.get(expose_promises) ++ [promise])
            name
          end)

        Promise.await(Promise.all(Process.delete(expose_promises)))
        serialized
      end,
      %{internal: true}
    )
  end

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

  defimpl String.Chars, for: PlaywrightEx.JSHandle do
    def to_string(this), do: PlaywrightEx.Client.JSHandle.to_string(this)
  end
end
