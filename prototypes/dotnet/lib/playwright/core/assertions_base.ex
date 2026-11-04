defmodule Playwright.Core.AssertionsBase do
  @moduledoc """
  upstream: Core/AssertionsBase.cs. C# abstract base class -> shared functions taking the concrete
  assertions struct; the abstract `CallExpectAsync` is a behaviour callback on that struct's module.
  `_defaultTimeout` (static mutable) -> :persistent_term.
  """
  alias Playwright.PlaywrightException
  alias Playwright.Helpers.RegexOptionsExtensions
  alias Playwright.Transport.Connection
  alias Playwright.Transport.Protocol.ExpectedTextValue
  alias Playwright.Transport.Protocol.FrameExpectOptions

  @callback call_expect_async(struct(), String.t(), struct(), String.t()) :: struct()

  # upstream: Core/AssertionsBase.cs:45
  defp default_timeout, do: :persistent_term.get({__MODULE__, :default_timeout}, 5_000)

  # upstream: Core/AssertionsBase.cs:57 (constructor: fields is_not/custom_message live on each struct)

  # upstream: Core/AssertionsBase.cs:59 + :61 (single ExpectedTextValue | array)
  def expect_impl_async(this, expression, %ExpectedTextValue{} = text_value, expected, message, title, options),
    do: expect_impl_async(this, expression, [text_value], expected, message, title, options)

  # upstream: Core/AssertionsBase.cs:64
  def expect_impl_async(this, expression, expected_text, expected, message, title, options) do
    options = options || %FrameExpectOptions{}
    options = %{options | expected_text: expected_text}
    options = %{options | is_not: this.is_not}
    expect_impl_async(this, expression, options, expected, message, title)
  end

  # upstream: Core/AssertionsBase.cs:72
  def expect_impl_async(this, expression, expect_options, expected, message, title) do
    expect_options = if expect_options.timeout == nil do
      %{expect_options | timeout: default_timeout()}
    else
      expect_options
    end
    message = if expect_options.is_not do
      String.replace(message, "expected to", "expected not to")
    else
      message
    end
    result = this.__struct__.call_expect_async(this, expression, expect_options, title)
    if result.matches == this.is_not do
      actual = result.received
      log = Connection.format_call_log(result.log)
      message = if result.error_message != nil, do: message <> "\n" <> result.error_message, else: message
      aria_snapshot_suffix = if result.received_aria_snapshot in [nil, ""], do: "", else: "\nAria snapshot:\n#{result.received_aria_snapshot}"
      prefix = if this.custom_message != nil, do: this.custom_message <> "\n\n", else: ""
      if expected == nil do
        raise PlaywrightException.new("#{prefix}#{message} #{log}#{aria_snapshot_suffix}")
      end
      raise PlaywrightException.new("#{prefix}#{message} '#{format_value(expected)}'\nBut was: '#{format_value(actual)}' #{log}#{aria_snapshot_suffix}")
    end
    :ok
  end

  # upstream: Core/AssertionsBase.cs:101
  def expected_regex(pattern, options \\ nil) do
    if pattern == nil do
      raise ArgumentError, "pattern"
    end

    text_value = options || %ExpectedTextValue{}
    {source, flags} = RegexOptionsExtensions.get_source_and_flags(pattern)
    text_value = %{text_value | regex_source: source}
    %{text_value | regex_flags: flags}
  end

  # upstream: Core/AssertionsBase.cs:115 (ClassUtils.Clone: copy same-named properties == struct/2)
  def convert_to_frame_expect_options(source), do: struct(FrameExpectOptions, source || [])

  # upstream: Core/AssertionsBase.cs:117
  defp format_value(value) do
    cond do
      value == nil -> "null"
      is_binary(value) -> value
      is_list(value) -> "[" <> Enum.map_join(value, ", ", &"'#{format_value(&1)}'") <> "]"
      is_struct(value, Regex) -> Regex.source(value)
      true -> to_string(value)
    end
  end

  # upstream: Core/AssertionsBase.cs:137
  def set_default_timeout(timeout), do: :persistent_term.put({__MODULE__, :default_timeout}, timeout)
end
