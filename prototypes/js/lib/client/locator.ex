# upstream: packages/playwright-core/src/client/locator.ts
# Locator is never mutated after construction -> plain immutable struct (no heap).
defmodule PlaywrightJS.Client.Locator do
  use PlaywrightJS.Client.Api
  alias PlaywrightJS.Client.Frame
  alias PlaywrightJS.Isomorphic.{LocatorUtils, StringUtils}

  defstruct [:_frame, :_selector, _apiName: "Locator"]

  # upstream: locator.ts:53
  def new(frame, selector, options \\ nil) do
    this = %__MODULE__{_frame: frame, _selector: selector}
    options = options || %{}

    this =
      if options[:hasText],
        do: %{this | _selector: this._selector <> " >> internal:has-text=#{StringUtils.escape_for_text_selector(options.hasText, false)}"},
        else: this

    this =
      if options[:hasNotText],
        do: %{
          this
          | _selector: this._selector <> " >> internal:has-not-text=#{StringUtils.escape_for_text_selector(options.hasNotText, false)}"
        },
        else: this

    this =
      if options[:has] do
        locator = options.has
        if locator._frame != frame, do: raise("Inner \"has\" locator must belong to the same frame.")
        %{this | _selector: this._selector <> " >> internal:has=" <> JSON.encode!(locator._selector)}
      else
        this
      end

    this =
      if options[:hasNot] do
        locator = options.hasNot
        if locator._frame != frame, do: raise("Inner \"hasNot\" locator must belong to the same frame.")
        %{this | _selector: this._selector <> " >> internal:has-not=" <> JSON.encode!(locator._selector)}
      else
        this
      end

    this =
      if options[:visible] != nil,
        do: %{this | _selector: this._selector <> " >> visible=#{if options.visible, do: "true", else: "false"}"},
        else: this

    # if (inspect.custom) ...  -- see Inspect impl below
    this
  end

  # upstream: locator.ts:101
  def _equals(this, locator) do
    this._frame == locator._frame and this._selector == locator._selector
  end

  # upstream: locator.ts:105
  def page(this) do
    Frame.page(this._frame)
  end

  # upstream: locator.ts:113
  def check(this, options \\ %{}) do
    Frame.check(this._frame, this._selector, Map.merge(%{strict: true}, options))
  end

  # upstream: locator.ts:117
  def click(this, options \\ %{}) do
    Frame.click(this._frame, this._selector, Map.merge(%{strict: true}, options))
    nil
  end

  # upstream: locator.ts:152
  def fill(this, value, options \\ %{}) do
    Frame.fill(this._frame, this._selector, value, Map.merge(%{strict: true}, options))
    nil
  end

  # upstream: locator.ts:175
  def locator(this, selector_or_locator, options \\ nil) do
    if is_binary(selector_or_locator) do
      new(this._frame, this._selector <> " >> " <> selector_or_locator, options)
    else
      if selector_or_locator._frame != this._frame, do: raise("Locators must belong to the same frame.")
      new(this._frame, this._selector <> " >> internal:chain=" <> JSON.encode!(selector_or_locator._selector), options)
    end
  end

  # upstream: locator.ts:187
  def get_by_test_id(this, test_id) do
    locator(this, LocatorUtils.get_by_test_id_selector(test_id_attribute_name(), test_id))
  end

  # upstream: locator.ts:195
  def get_by_label(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_label_selector(text, options))
  end

  # upstream: locator.ts:211
  def get_by_role(this, role, options \\ %{}) do
    locator(this, LocatorUtils.get_by_role_selector(role, options))
  end

  # upstream: locator.ts:355
  def select_option(this, values, options \\ %{}) do
    Frame.select_option(this._frame, this._selector, values, Map.merge(%{strict: true}, options))
  end

  # upstream: locator.ts:370
  def set_input_files(this, files, options \\ %{}) do
    Frame.set_input_files(this._frame, this._selector, files, Map.merge(%{strict: true}, options))
  end

  # upstream: locator.ts:423
  def _expect(this, expression, options) do
    Frame._expect(this._frame, expression, Map.merge(options, %{selector: this._selector}))
  end

  # upstream: locator.ts:434 (toString -> asLocatorDescription; locatorGenerators.ts not ported)
  def to_string(this) do
    "locator(#{JSON.encode!(this._selector)})"
  end

  # upstream: locator.ts:519
  def test_id_attribute_name do
    :persistent_term.get({__MODULE__, :test_id_attribute_name}, "data-testid")
  end

  # upstream: locator.ts:523
  def set_test_id_attribute(attribute_name) do
    :persistent_term.put({__MODULE__, :test_id_attribute_name}, attribute_name)
  end

  defimpl Inspect do
    def inspect(locator, _opts), do: PlaywrightJS.Client.Locator.to_string(locator)
  end
end
