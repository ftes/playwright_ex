defmodule Playwright.Core.LocatorAssertions do
  @moduledoc "upstream: Core/LocatorAssertions.cs (subset)"
  @behaviour Playwright.Core.AssertionsBase

  alias Playwright.Core.Locator
  alias Playwright.Core.ScriptsHelper
  alias Playwright.Transport.Protocol.ExpectedTextValue
  import Playwright.Core.AssertionsBase

  defstruct [:actual_locator, :is_not, :custom_message]

  # upstream: Core/LocatorAssertions.cs:35
  def new(locator, is_not, custom_message \\ nil), do: %__MODULE__{actual_locator: locator, is_not: is_not, custom_message: custom_message}

  # upstream: Core/LocatorAssertions.cs:42
  def not_(this), do: new(this.actual_locator, !this.is_not, this.custom_message)

  # upstream: Core/LocatorAssertions.cs:44
  @impl true
  def call_expect_async(this, expression, expect_options, title) do
    Locator.expect_async(this.actual_locator, expression, expect_options, title)
  end

  # upstream: Core/LocatorAssertions.cs:55
  def to_be_checked_async(this, options \\ nil) do
    expected_value = %{}
    expected_value = if options[:checked] != nil, do: Map.put(expected_value, "checked", options[:checked]), else: expected_value
    expected_value = if options[:indeterminate] != nil, do: Map.put(expected_value, "indeterminate", options[:indeterminate]), else: expected_value
    frame_expected_options = convert_to_frame_expect_options(options)
    frame_expected_options = %{frame_expected_options | expected_value: ScriptsHelper.serialized_argument(expected_value)}
    checked_string = if options[:indeterminate] == true, do: "indeterminate", else: "checked"
    expect_true_async(this, "to.be.checked", "Locator expected #{if options[:checked] == false, do: "not ", else: ""}to be #{checked_string}", "Expect \"ToBeCheckedAsync\"", frame_expected_options)
  end

  # upstream: Core/LocatorAssertions.cs:108
  defp expect_true_async(this, expression, message, title, options) do
    expect_impl_async(this, expression, nil, nil, message, title, options)
  end

  # upstream: Core/LocatorAssertions.cs:203 + :206 + :209 + :212
  def to_have_text_async(this, expected, options \\ nil)

  def to_have_text_async(this, %Regex{} = expected, options) do
    expect_impl_async(this, "to.have.text", expected_regex(expected, %ExpectedTextValue{normalize_white_space: true, ignore_case: options[:ignore_case] || false}), expected, "Locator expected to have text matching regex", "Expect \"ToHaveTextAsync\"", convert_to_frame_expect_options(options))
  end

  def to_have_text_async(this, expected, options) when is_list(expected) do
    expect_impl_async(this, "to.have.text.array", Enum.map(expected, fn
      %Regex{} = regex -> expected_regex(regex, %ExpectedTextValue{normalize_white_space: true, ignore_case: options[:ignore_case] || false})
      text -> %ExpectedTextValue{string: text, normalize_white_space: true, ignore_case: options[:ignore_case] || false}
    end), expected, "Locator expected to have text", "Expect \"ToHaveTextAsync\"", convert_to_frame_expect_options(options))
  end

  def to_have_text_async(this, expected, options) do
    expect_impl_async(this, "to.have.text", %ExpectedTextValue{string: expected, normalize_white_space: true, ignore_case: options[:ignore_case] || false}, expected, "Locator expected to have text", "Expect \"ToHaveTextAsync\"", convert_to_frame_expect_options(options))
  end
end
