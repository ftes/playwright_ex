defmodule PlaywrightEx.Client.Locator do
  @upstream "packages/playwright-core/src/client/locator.ts"
  @moduledoc "Port of `#{@upstream}` (`class Locator`). Locators hold no mutable state: a plain struct."

  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.ElementHandle
  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.FrameLocator
  alias PlaywrightEx.Client.JSHandle
  alias PlaywrightEx.Client.LocalUtils
  alias PlaywrightEx.Client.TimeoutSettings
  alias PlaywrightEx.Isomorphic.LocatorUtils
  alias PlaywrightEx.Isomorphic.StringUtils
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap

  defstruct [:_frame, :_selector, _apiName: "Locator"]

  # selectorParser.ts kAnyFrameSelector
  @doc false
  def k_any_frame_selector, do: "internal:control=any-frame"

  def new(frame, selector, options \\ nil) do
    selector =
      if truthy(options[:hasText]),
        do: selector <> " >> internal:has-text=#{StringUtils.escape_for_text_selector(options.hasText, false)}",
        else: selector

    selector =
      if truthy(options[:hasNotText]),
        do: selector <> " >> internal:has-not-text=#{StringUtils.escape_for_text_selector(options.hasNotText, false)}",
        else: selector

    selector =
      if options[:has] do
        locator = options.has
        if locator._frame != frame, do: raise(~s(Inner "has" locator must belong to the same frame.))
        selector <> " >> internal:has=" <> JSON.encode!(locator._selector)
      else
        selector
      end

    selector =
      if options[:hasNot] do
        locator = options.hasNot
        if locator._frame != frame, do: raise(~s(Inner "hasNot" locator must belong to the same frame.))
        selector <> " >> internal:has-not=" <> JSON.encode!(locator._selector)
      else
        selector
      end

    selector =
      if options[:visible] != nil,
        do: selector <> " >> visible=#{if options.visible, do: "true", else: "false"}",
        else: selector

    # if (inspect.custom) (this as any)[inspect.custom] = () => this._inspect();  -- ported as Inspect, see below
    %__MODULE__{_frame: frame, _selector: selector}
  end

  defp _with_element(this, task, options) do
    timeout = Frame._timeout(this._frame, %{timeout: options[:timeout]}).timeout
    deadline = if timeout != 0, do: monotonic_time() + timeout, else: 0

    ChannelOwner._wrap_api_call(
      this._frame,
      fn _ ->
        result =
          ChannelOwner.channel_call(
            this._frame,
            :waitForSelector,
            %{selector: this._selector, strict: true, state: "attached"},
            # { signal: options.signal, timeout }  -- signal not ported: AbortSignal
            %{timeout: timeout}
          )

        handle = ElementHandle.from_nullable(result[:element])
        if !handle, do: raise("Could not resolve #{this._selector} to DOM Element")

        try do
          task.(handle, if(deadline != 0, do: deadline - monotonic_time(), else: 0))
        after
          JSHandle.dispose(handle)
        end
      end,
      %{title: options.title, internal: options[:internal]}
    )
  end

  def _equals(this, locator) do
    this._frame == locator._frame and this._selector == locator._selector
  end

  def page(this) do
    Frame.page(this._frame)
  end

  def bounding_box(this, options \\ nil) do
    _with_element(this, fn h, _ -> ElementHandle.bounding_box(h) end, %{
      title: "Bounding box",
      timeout: options[:timeout]
    })
  end

  def check(this, options \\ %{}) do
    Frame.check(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def click(this, options \\ %{}) do
    Frame.click(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def dblclick(this, options \\ %{}) do
    Frame.dblclick(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
    nil
  end

  def dispatch_event(this, type, event_init \\ nil, options \\ nil) do
    event_init = if event_init == nil, do: %{}, else: event_init
    Frame.dispatch_event(this._frame, this._selector, type, event_init, Map.merge(%{strict: true}, options || %{}))
  end

  def drag_to(this, target, options \\ %{}) do
    Frame.drag_and_drop(this._frame, this._selector, target._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def drop(this, payload, options \\ %{}) do
    Frame._drop(this._frame, this._selector, payload, Map.merge(%{strict: true}, options || %{}))
  end

  def evaluate(this, page_function, arg \\ nil, options \\ nil) do
    _with_element(this, fn h, _ -> JSHandle.evaluate(h, page_function, arg, options) end, %{
      title: "Evaluate",
      timeout: options[:timeout]
    })
  end

  def evaluate_all(this, page_function, arg \\ nil) do
    Frame.eval_on_selector_all(this._frame, this._selector, page_function, arg)
  end

  def evaluate_handle(this, page_function, arg \\ nil, options \\ nil) do
    _with_element(this, fn h, _ -> JSHandle.evaluate_handle(h, page_function, arg, options) end, %{
      title: "Evaluate",
      timeout: options[:timeout]
    })
  end

  def fill(this, value, options \\ %{}) do
    Frame.fill(this._frame, this._selector, value, Map.merge(%{strict: true}, options || %{}))
  end

  def clear(this, options \\ %{}) do
    ChannelOwner._wrap_api_call(this._frame, fn _ -> fill(this, "", options) end, %{title: "Clear"})
    nil
  end

  def _highlight(this) do
    # VS Code extension uses this one, keep it for now.
    Frame._highlight(this._frame, this._selector)
  end

  # highlight  -- not ported: Disposable

  def hide_highlight(this) do
    Frame._hide_highlight(this._frame, this._selector)
  end

  def locator(this, selector_or_locator, options \\ nil) do
    if is_binary(selector_or_locator) do
      new(this._frame, this._selector <> " >> " <> selector_or_locator, options)
    else
      if selector_or_locator._frame != this._frame, do: raise("Locators must belong to the same frame.")
      new(this._frame, this._selector <> " >> internal:chain=" <> JSON.encode!(selector_or_locator._selector), options)
    end
  end

  def within(this, locator) do
    locator(locator, this)
  end

  def get_by_test_id(this, test_id) do
    locator(this, LocatorUtils.get_by_test_id_selector(test_id_attribute_name(), test_id))
  end

  def get_by_alt_text(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_alt_text_selector(text, options))
  end

  def get_by_label(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_label_selector(text, options))
  end

  def get_by_placeholder(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_placeholder_selector(text, options))
  end

  def get_by_text(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_text_selector(text, options))
  end

  def get_by_title(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_title_selector(text, options))
  end

  def get_by_role(this, role, options \\ %{}) do
    locator(this, LocatorUtils.get_by_role_selector(role, options || %{}))
  end

  def frame_locator(this, selector) do
    FrameLocator.new(this._frame, this._selector <> " >> " <> selector)
  end

  def filter(this, options \\ nil) do
    new(this._frame, this._selector, options)
  end

  def visible(this) do
    new(this._frame, this._selector, %{visible: true})
  end

  def element_handle(this, options \\ nil) do
    Frame.wait_for_selector(this._frame, this._selector, Map.merge(%{strict: true, state: "attached"}, options || %{}))
  end

  def element_handles(this) do
    Frame.query_selector_all(this._frame, this._selector)
  end

  def content_frame(this) do
    FrameLocator.new(this._frame, this._selector)
  end

  def describe(this, description) do
    new(this._frame, this._selector <> " >> internal:describe=" <> JSON.encode!(description))
  end

  def description(this) do
    # locatorCustomDescription(this._selector) || null
    case locator_custom_description(this._selector) do
      "" -> nil
      description -> description
    end
  end

  def first(this) do
    new(this._frame, this._selector <> " >> nth=0")
  end

  def last(this) do
    new(this._frame, this._selector <> " >> nth=-1")
  end

  def nth(this, index) do
    new(this._frame, this._selector <> " >> nth=#{index}")
  end

  # and  -- ported as and_/2 (a reserved word, as Python's and_)
  def and_(this, locator) do
    if locator._frame != this._frame, do: raise("Locators must belong to the same frame.")
    new(this._frame, this._selector <> " >> internal:and=" <> JSON.encode!(locator._selector))
  end

  # or  -- ported as or_/2 (a reserved word, as Python's or_)
  def or_(this, locator) do
    if locator._frame != this._frame, do: raise("Locators must belong to the same frame.")
    new(this._frame, this._selector <> " >> internal:or=" <> JSON.encode!(locator._selector))
  end

  def focus(this, options \\ nil) do
    Frame.focus(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def blur(this, options \\ nil) do
    ChannelOwner.channel_call(
      this._frame,
      :blur,
      Map.merge(%{selector: this._selector, strict: true}, options || %{}),
      Frame._timeout(this._frame, options)
    )

    nil
  end

  def count(this) do
    Frame._query_count(this._frame, this._selector)
  end

  def normalize(this) do
    %{resolvedSelector: resolved_selector} =
      ChannelOwner.channel_call(
        this._frame,
        :resolveSelector,
        %{selector: this._selector},
        TimeoutSettings.k_no_timeout()
      )

    new(this._frame, resolved_selector)
  end

  def get_attribute(this, name, options \\ nil) do
    Frame.get_attribute(this._frame, this._selector, name, Map.merge(%{strict: true}, options || %{}))
  end

  def hover(this, options \\ %{}) do
    Frame.hover(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def inner_html(this, options \\ nil) do
    Frame.inner_html(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def inner_text(this, options \\ nil) do
    Frame.inner_text(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def input_value(this, options \\ nil) do
    Frame.input_value(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def is_checked(this, options \\ nil) do
    Frame.is_checked(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def is_disabled(this, options \\ nil) do
    Frame.is_disabled(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def is_editable(this, options \\ nil) do
    Frame.is_editable(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def is_enabled(this, options \\ nil) do
    Frame.is_enabled(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def is_hidden(this, options \\ nil) do
    Frame.is_hidden(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def is_visible(this, options \\ nil) do
    Frame.is_visible(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def press(this, key, options \\ %{}) do
    Frame.press(this._frame, this._selector, key, Map.merge(%{strict: true}, options || %{}))
  end

  def screenshot(this, options \\ %{}) do
    options = options || %{}
    mask = options[:mask]

    _with_element(
      this,
      fn h, timeout -> ElementHandle.screenshot(h, Map.merge(options, %{mask: mask, timeout: timeout})) end,
      %{title: "Screenshot", timeout: options[:timeout]}
    )
  end

  def aria_snapshot(this, options \\ %{}) do
    options = options || %{}

    result =
      ChannelOwner.channel_call(
        this._frame,
        :ariaSnapshot,
        %{mode: options[:mode], selector: this._selector, depth: options[:depth], boxes: options[:boxes]},
        Frame._timeout(this._frame, options)
      )

    result.snapshot
  end

  def aria_snapshot_json(this, options \\ %{}) do
    options = options || %{}

    result =
      ChannelOwner.channel_call(
        this._frame,
        :ariaSnapshotJSON,
        %{mode: options[:mode], selector: this._selector, depth: options[:depth], boxes: options[:boxes]},
        Frame._timeout(this._frame, options)
      )

    result.snapshot
  end

  def scroll_into_view_if_needed(this, options \\ %{}) do
    options = options || %{}

    _with_element(
      this,
      fn h, timeout -> ElementHandle.scroll_into_view_if_needed(h, Map.put(options, :timeout, timeout)) end,
      %{title: "Scroll into view", timeout: options[:timeout]}
    )
  end

  def select_option(this, values, options \\ %{}) do
    Frame.select_option(this._frame, this._selector, values, Map.merge(%{strict: true}, options || %{}))
  end

  def select_text(this, options \\ %{}) do
    options = options || %{}

    _with_element(
      this,
      fn h, timeout -> ElementHandle.select_text(h, Map.put(options, :timeout, timeout)) end,
      %{title: "Select text", timeout: options[:timeout]}
    )
  end

  def set_checked(this, checked, options \\ nil) do
    if checked,
      do: check(this, options),
      else: uncheck(this, options)

    nil
  end

  def set_input_files(this, files, options \\ %{}) do
    Frame.set_input_files(this._frame, this._selector, files, Map.merge(%{strict: true}, options || %{}))
  end

  def tap(this, options \\ %{}) do
    Frame.tap(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def text_content(this, options \\ nil) do
    Frame.text_content(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def type(this, text, options \\ %{}) do
    Frame.type(this._frame, this._selector, text, Map.merge(%{strict: true}, options || %{}))
  end

  def press_sequentially(this, text, options \\ %{}) do
    type(this, text, options)
  end

  def uncheck(this, options \\ %{}) do
    Frame.uncheck(this._frame, this._selector, Map.merge(%{strict: true}, options || %{}))
  end

  def all(this) do
    for i <- 0..(count(this) - 1)//1, do: nth(this, i)
  end

  def all_inner_texts(this) do
    Frame.eval_on_selector_all(this._frame, this._selector, "ee => ee.map(e => e.innerText)")
  end

  def all_text_contents(this) do
    Frame.eval_on_selector_all(this._frame, this._selector, "ee => ee.map(e => e.textContent || '')")
  end

  def wait_for(this, options \\ nil) do
    ChannelOwner.channel_call(
      this._frame,
      :waitForSelector,
      Map.merge(%{selector: this._selector, strict: true, omitReturnValue: true}, options || %{}),
      Frame._timeout(this._frame, options)
    )

    nil
  end

  def wait_for_function(this, page_function, arg \\ nil, options \\ nil) do
    ChannelOwner.channel_call(
      this._frame,
      :waitForFunction,
      %{
        selector: this._selector,
        strict: true,
        expression: page_function,
        # isFunction: typeof pageFunction === 'function',  -- omitted: page functions are JS source (PLAN)
        arg: JSHandle.serialize_argument(arg)
      },
      Frame._timeout(this._frame, options)
    )

    nil
  end

  def _expect(this, expression, options) do
    Frame._expect(this._frame, expression, Map.put(options, :selector, this._selector))
  end

  # _inspect  -- ported as Inspect, see below

  # asLocatorDescription through the driver (PLAN, Decisions): a sync member that needs the baton.
  def to_string(this) do
    EventLoop.with_baton(this._frame.loop, fn ->
      LocalUtils.as_locator_description(Connection.local_utils(Heap.get(this._frame, :_connection)), %{
        selector: this._selector,
        sdkLanguage: "javascript"
      })
    end)
  end

  # locator.ts module functions

  # `_testIdAttributeName` is module state, shared by every connection as in JS.
  def test_id_attribute_name do
    :persistent_term.get({__MODULE__, :test_id_attribute_name}, "data-testid")
  end

  def set_test_id_attribute(attribute_name) do
    :persistent_term.put({__MODULE__, :test_id_attribute_name}, attribute_name)
  end

  # cssObjectToString  -- not ported: highlight

  # locatorGenerators.ts locatorCustomDescription: the last part of the selector if it is
  # `internal:describe`. Without parseSelector: describe() appends it as a JSON string.
  defp locator_custom_description(selector) do
    case Regex.run(~r/(?:^| >> )internal:describe=("(?:[^"\\]|\\.)*")$/, selector) do
      [_, json] -> JSON.decode!(json)
      nil -> nil
    end
  end

  # utils monotonicTime(), in milliseconds.
  defp monotonic_time, do: System.monotonic_time(:millisecond)

  # JS truthiness of a `string | RegExp` option.
  defp truthy(value), do: value not in [nil, false, ""]

  # Elixir only: `#PlaywrightEx.Locator<selector>`, like the handles (`toString` needs the driver).
  defimpl Inspect do
    def inspect(this, _opts), do: "#PlaywrightEx.Locator<#{this._selector}>"
  end
end

defmodule PlaywrightEx.Client.FrameLocator do
  @upstream "packages/playwright-core/src/client/locator.ts"
  @moduledoc "Port of `#{@upstream}` (`class FrameLocator`)."

  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Isomorphic.LocatorUtils

  defstruct [:_frame, :_frameSelector]

  def new(frame, selector) do
    %__MODULE__{_frame: frame, _frameSelector: selector}
  end

  defp _child_selector(this, selector) do
    if this._frameSelector == Locator.k_any_frame_selector(),
      do: this._frameSelector <> " >> " <> selector,
      else: this._frameSelector <> " >> internal:control=enter-frame >> " <> selector
  end

  def locator(this, selector_or_locator, options \\ nil) do
    if is_binary(selector_or_locator) do
      Locator.new(this._frame, _child_selector(this, selector_or_locator), options)
    else
      if selector_or_locator._frame != this._frame, do: raise("Locators must belong to the same frame.")
      Locator.new(this._frame, _child_selector(this, selector_or_locator._selector), options)
    end
  end

  def get_by_test_id(this, test_id) do
    locator(this, LocatorUtils.get_by_test_id_selector(Locator.test_id_attribute_name(), test_id))
  end

  def get_by_alt_text(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_alt_text_selector(text, options))
  end

  def get_by_label(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_label_selector(text, options))
  end

  def get_by_placeholder(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_placeholder_selector(text, options))
  end

  def get_by_text(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_text_selector(text, options))
  end

  def get_by_title(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_title_selector(text, options))
  end

  def get_by_role(this, role, options \\ %{}) do
    locator(this, LocatorUtils.get_by_role_selector(role, options || %{}))
  end

  def owner(this) do
    Locator.new(this._frame, this._frameSelector)
  end

  def frame_locator(this, selector) do
    new(this._frame, _child_selector(this, selector))
  end

  defp _nth_selector(this, nth) do
    if this._frameSelector == Locator.k_any_frame_selector(),
      do: raise("Selecting the nth frame is not allowed on frameLocator().")

    this._frameSelector <> " >> nth=#{nth}"
  end

  def first(this) do
    new(this._frame, _nth_selector(this, "0"))
  end

  def last(this) do
    new(this._frame, _nth_selector(this, "-1"))
  end

  def nth(this, index) do
    new(this._frame, _nth_selector(this, to_string(index)))
  end

  defimpl Inspect do
    def inspect(this, _opts), do: "#PlaywrightEx.FrameLocator<#{this._frameSelector}>"
  end
end
