# upstream: packages/playwright/src/matchers/expect.ts (createExpect/createMatchers/callMatcherAsStep/invokeMatcher subset)
#
#   await expect(page).toHaveTitle('x')        ->  expect(page) |> to_have_title("x")
#   await expect(locator).not.toBeChecked()     ->  expect(locator) |> not_() |> to_be_checked()
defmodule PlaywrightJS.Matchers.Expect do
  alias PlaywrightJS.Matchers.{Matchers, MatcherHint.ExpectError}
  alias PlaywrightJS.Isomorphic.StringUtils

  defstruct [:actual, info: %{isNot: false, message: nil, timeout: nil, isSoft: false, poll: nil}]

  @default_expect_timeout 5000

  # upstream: expect.ts:227 (expectFn)
  def expect(actual, message_or_options \\ nil) do
    info = %__MODULE__{}.info
    message = if is_binary(message_or_options), do: message_or_options, else: (message_or_options || %{})[:message]
    timeout = if is_map(message_or_options), do: message_or_options[:timeout]
    %__MODULE__{actual: actual, info: %{info | message: message, timeout: timeout}}
  end

  # upstream: expect.ts:312 (result.not)
  def not_(%__MODULE__{} = e), do: %{e | info: %{e.info | isNot: !e.info.isNot}}

  # upstream: expect.ts:313 (one createMatcher per builtin matcher)
  def to_be_checked(e, options \\ nil), do: call_matcher_as_step("toBeChecked", e.info, e.actual, &Matchers.to_be_checked/3, [options])

  def to_have_text(e, expected, options \\ %{}),
    do: call_matcher_as_step("toHaveText", e.info, e.actual, &Matchers.to_have_text/4, [expected, options])

  def to_have_title(e, expected, options \\ %{}),
    do: call_matcher_as_step("toHaveTitle", e.info, e.actual, &Matchers.to_have_title/4, [expected, options])

  def to_have_url(e, expected, options \\ nil),
    do: call_matcher_as_step("toHaveURL", e.info, e.actual, &Matchers.to_have_url/4, [expected, options])

  # upstream: expect.ts:329
  defp call_matcher_as_step(matcher_name, info, actual, matcher, args) do
    # const testInfo = expectConfig().testInfo;  -- not ported: test runner
    custom_message = info.message || ""
    default_title = "#{if info.poll, do: "poll "}#{if info.isSoft, do: "soft "}#{if info.isNot, do: "not "}#{matcher_name}"
    title = if custom_message != "", do: custom_message, else: "Expect \"#{default_title}\""
    # stackFrames / params / stepData / testInfo._addStep  -- not ported: test runner

    result = invoke_matcher(matcher_name, info, matcher, actual, args, nil, title)

    # finalizer
    if result.pass == !!info.isNot do
      raise ExpectError.new(Map.merge(result, %{name: matcher_name, message: result.message.()}), custom_message, [])
    end

    nil
  end

  # upstream: expect.ts:383
  defp invoke_matcher(_matcher_name, info, matcher, actual, args, promise, title) do
    is_not = !!info.isNot
    timeout = info.timeout || @default_expect_timeout

    matcher_context = %{
      isNot: is_not,
      promise: promise || "",
      utils: utils(),
      timeout: timeout,
      title: title
    }

    apply(matcher, [matcher_context, actual | args])
  end

  # Subset of jest-matcher-utils used by the matchers (expectLibrary.ts); colors are no-ops.
  defp utils do
    id = fn s -> s end

    %{
      dim_color: id,
      received_color: id,
      inverted_color: id,
      expected_color: id,
      print_expected: &print_value/1,
      print_received: &print_value/1,
      print_diff_or_stringify: fn expected, received, expected_label, received_label, _expand ->
        "#{expected_label}: #{print_value(expected)}\n#{received_label}: #{print_value(received)}"
      end
    }
  end

  defp print_value(%Regex{} = re), do: StringUtils.regex_to_string(re)
  defp print_value(value) when is_binary(value), do: JSON.encode!(value)
  defp print_value(value), do: inspect(value)
end
