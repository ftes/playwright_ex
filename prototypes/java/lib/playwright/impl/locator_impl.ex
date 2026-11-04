defmodule Playwright.Impl.LocatorImpl do
  # upstream: LocatorImpl.java:35  (not a ChannelOwner: an immutable value)
  alias Playwright.{Frame, Locator}
  alias Playwright.Impl.{FrameImpl, Utils}
  import Playwright.Impl.LocatorUtils

  defstruct [:frame, :selector, :string_representation]
  @type t :: %__MODULE__{}

  # upstream: LocatorImpl.java:40
  def new(frame, selector, options), do: new(frame, selector, options, nil)

  # upstream: LocatorImpl.java:44  (has/hasNot/hasNotText not ported)
  defp new(frame, selector, options, visible) do
    selector =
      if options != nil and options.has_text != nil,
        do: selector <> " >> internal:has-text=" <> escape_for_text_selector(options.has_text, false),
        else: selector

    selector = if visible != nil, do: selector <> " >> visible=" <> to_string(visible), else: selector
    %__MODULE__{frame: frame, selector: selector}
  end

  # upstream: LocatorImpl.java:162
  def check(this, options) do
    options = options || %Locator.CheckOptions{}
    FrameImpl.check(this.frame, this.selector, struct!(Utils.convert_type(options, Frame.CheckOptions), strict: true))
  end

  # upstream: LocatorImpl.java:175
  def click(this, options) do
    options = options || %Locator.ClickOptions{}

    FrameImpl.click_impl(
      this.frame,
      this.selector,
      struct!(Utils.convert_type(options, Frame.ClickOptions), strict: true),
      options.steps
    )
  end

  # upstream: LocatorImpl.java:276
  def fill(this, value, options) do
    options = options || %Locator.FillOptions{}

    FrameImpl.fill(
      this.frame,
      this.selector,
      value,
      struct!(Utils.convert_type(options, Frame.FillOptions), strict: true)
    )
  end

  # upstream: LocatorImpl.java:331
  def get_by_label(this, text, options) when is_binary(text),
    do: locator(this, get_by_label_selector(text, options), nil)

  # upstream: LocatorImpl.java:336
  def get_by_label(this, %Regex{} = text, options), do: locator(this, get_by_label_selector(text, options), nil)

  # upstream: LocatorImpl.java:351
  def get_by_role(this, role, options), do: locator(this, get_by_role_selector(role, options), nil)

  # upstream: LocatorImpl.java:356
  def get_by_test_id(this, test_id) when is_binary(test_id) do
    locator(this, get_by_test_id_selector(test_id, Playwright.Impl.Heap.get(this.frame.connection, :playwright)), nil)
  end

  # upstream: LocatorImpl.java:361
  def get_by_test_id(this, %Regex{} = test_id) do
    locator(this, get_by_test_id_selector(test_id, Playwright.Impl.Heap.get(this.frame.connection, :playwright)), nil)
  end

  # upstream: LocatorImpl.java:488
  def locator(this, selector, options) when is_binary(selector),
    do: new(this.frame, this.selector <> " >> " <> selector, options)

  # upstream: LocatorImpl.java:515
  def page(this), do: FrameImpl.page(this.frame)

  # upstream: LocatorImpl.java:546
  def select_option(this, values, options) when is_binary(values) do
    options = options || %Locator.SelectOptionOptions{}

    FrameImpl.select_option(
      this.frame,
      this.selector,
      values,
      struct!(Utils.convert_type(options, Frame.SelectOptionOptions), strict: true)
    )
  end

  # upstream: LocatorImpl.java:562
  def select_option(this, values, options) when is_list(values) do
    options = options || %Locator.SelectOptionOptions{}

    FrameImpl.select_option(
      this.frame,
      this.selector,
      values,
      struct!(Utils.convert_type(options, Frame.SelectOptionOptions), strict: true)
    )
  end

  # upstream: LocatorImpl.java:610
  def set_input_files(this, files, options) when is_binary(files) do
    options = options || %Locator.SetInputFilesOptions{}

    FrameImpl.set_input_files(
      this.frame,
      this.selector,
      files,
      struct!(Utils.convert_type(options, Frame.SetInputFilesOptions), strict: true)
    )
  end

  # upstream: LocatorImpl.java:618
  def set_input_files(this, files, options) when is_list(files) do
    options = options || %Locator.SetInputFilesOptions{}

    FrameImpl.set_input_files(
      this.frame,
      this.selector,
      files,
      struct!(Utils.convert_type(options, Frame.SetInputFilesOptions), strict: true)
    )
  end

  defimpl String.Chars do
    # upstream: LocatorImpl.java:697  (description() not ported)
    def to_string(this), do: this.string_representation || "Locator@" <> this.selector
  end

  # upstream: LocatorImpl.java:722
  def expect(this, expression, options, title) do
    options = %{options | selector: this.selector}
    FrameImpl.expect(this.frame, expression, options, title)
  end

  # upstream: LocatorImpl.java:727
  def to_protocol(this), do: %{"frame" => %{"guid" => this.frame.guid}, "selector" => this.selector}
end
