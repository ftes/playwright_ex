defmodule Playwright.Impl.AssertionsBase do
  # upstream: AssertionsBase.java:31  (abstract class; subclasses `use` it and implement do_expect/4)
  alias Playwright.Impl.{AssertionsTimeout, Serialization, Utils}
  alias Playwright.Impl.Protocol.{ExpectedTextValue, FrameExpectOptions}

  @callback do_expect(struct(), String.t(), struct(), String.t()) :: struct()

  defmacro __using__(_) do
    quote do
      @behaviour Playwright.Impl.AssertionsBase
      alias Playwright.Impl.AssertionsBase

      import Playwright.Impl.AssertionsBase,
        only: [expect_impl: 7, expect_impl: 6, expected_regex: 1, should_ignore_case: 1]
    end
  end

  # upstream: AssertionsBase.java:38 + :42 (single value vs list overloads)
  def expect_impl(this, expression, %ExpectedTextValue{} = text_value, expected, message, options, title) do
    expect_impl(this, expression, [text_value], expected, message, options, title)
  end

  def expect_impl(this, expression, expected_text, expected, message, options, title) when is_list(expected_text) do
    options = options || %FrameExpectOptions{}
    options = %{options | expected_text: expected_text}
    expect_impl(this, expression, options, expected, message, title)
  end

  # upstream: AssertionsBase.java:50
  def expect_impl(this, expression, expect_options, expected, message, title) do
    expect_options =
      if expect_options.timeout == nil,
        do: %{expect_options | timeout: AssertionsTimeout.default_timeout()},
        else: expect_options

    expect_options = %{expect_options | is_not: this.is_not}
    message = if this.is_not, do: String.replace(message, "expected to", "expected not to"), else: message
    result = this.__struct__.do_expect(this, expression, expect_options, title)

    if result.matches == this.is_not do
      actual =
        cond do
          result.received == nil -> nil
          result.received["value"] != nil -> Serialization.deserialize(result.received["value"])
          true -> result.received["ariaSnapshot"]
        end

      log = if result.log == nil, do: "", else: Enum.join(result.log, "\n")
      log = if log != "", do: "\nCall log:\n" <> log, else: log
      message = if result.error_message != nil, do: message <> "\n" <> result.error_message, else: message

      # opentest4j AssertionFailedError -> ExUnit.AssertionError
      if expected == nil, do: raise(ExUnit.AssertionError, message: message <> log)
      expected_value = format_value(expected)
      actual_value = format_value(actual)
      message = message <> "\nExpected: " <> expected_value <> "\nReceived: " <> actual_value <> "\n"
      raise ExUnit.AssertionError, message: message <> log, left: actual, right: expected
    end
  end

  # upstream: AssertionsBase.java:87
  defp format_value(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &to_string/1) <> "]"
  defp format_value(%Regex{} = value), do: Regex.source(value)
  defp format_value(value), do: to_string(value)

  # upstream: AssertionsBase.java:96
  def expected_regex(pattern) do
    expected = %ExpectedTextValue{regex_source: Regex.source(pattern)}
    if Regex.opts(pattern) != [], do: %{expected | regex_flags: Utils.to_js_regex_flags(pattern)}, else: expected
  end

  # upstream: AssertionsBase.java:105  (reflection on an `ignoreCase` field -> Map.get)
  def should_ignore_case(nil), do: nil
  def should_ignore_case(options), do: Map.get(options, :ignore_case)
end
