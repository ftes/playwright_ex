defmodule Playwright.Impl.LocatorAssertionsImpl do
  # upstream: LocatorAssertionsImpl.java:32
  use Playwright.Impl.AssertionsBase
  alias Playwright.Assertions.LocatorAssertions.IsCheckedOptions
  alias Playwright.Impl.{LocatorImpl, Serialization, Utils}
  alias Playwright.Impl.Protocol.{ExpectedTextValue, FrameExpectOptions}

  defstruct [:actual_locator, is_not: false]
  @type t :: %__MODULE__{}

  # upstream: LocatorAssertionsImpl.java:35
  def new(locator), do: new(locator, false)

  # upstream: LocatorAssertionsImpl.java:39
  defp new(locator, is_not), do: %__MODULE__{actual_locator: locator, is_not: is_not}

  # upstream: LocatorAssertionsImpl.java:45
  @impl true
  def do_expect(this, expression, expect_options, title),
    do: LocatorImpl.expect(this.actual_locator, expression, expect_options, title)

  # upstream: LocatorAssertionsImpl.java:297
  def has_text(this, text, options) when is_binary(text) do
    expected = %ExpectedTextValue{}
    expected = %{expected | string: text}
    expected = %{expected | ignore_case: should_ignore_case(options)}
    expected = %{expected | match_substring: false}
    expected = %{expected | normalize_white_space: true}

    expect_impl(
      this,
      "to.have.text",
      expected,
      text,
      "Locator expected to have text",
      Utils.convert_type(options, FrameExpectOptions),
      "Assert \"hasText\""
    )
  end

  # upstream: LocatorAssertionsImpl.java:307
  def has_text(this, %Regex{} = pattern, options) do
    expected = expected_regex(pattern)
    expected = %{expected | ignore_case: should_ignore_case(options)}
    # Just match substring, same as containsText.
    expected = %{expected | match_substring: true}
    expected = %{expected | normalize_white_space: true}

    expect_impl(
      this,
      "to.have.text",
      expected,
      pattern,
      "Locator expected to have text matching regex",
      Utils.convert_type(options, FrameExpectOptions),
      "Assert \"hasText\""
    )
  end

  # upstream: LocatorAssertionsImpl.java:389
  def is_checked(this, options) do
    options = options || %IsCheckedOptions{}

    expected_value = %{}

    expected_value =
      if options.indeterminate != nil,
        do: Map.put(expected_value, "indeterminate", options.indeterminate),
        else: expected_value

    expected_value =
      if options.checked != nil, do: Map.put(expected_value, "checked", options.checked), else: expected_value

    expected =
      if options.indeterminate != nil and options.indeterminate do
        "indeterminate"
      else
        unchecked = options.checked != nil and !options.checked
        if unchecked, do: "unchecked", else: "checked"
      end

    message = "Locator expected to be"
    expect_options = Utils.convert_type(options, FrameExpectOptions)
    expect_options = %{expect_options | expected_value: Serialization.serialize_argument(expected_value)}
    expect_impl(this, "to.be.checked", expect_options, expected, message, "Assert \"isChecked\"")
  end

  # upstream: LocatorAssertionsImpl.java:475
  def not_(this), do: new(this.actual_locator, !this.is_not)
end
