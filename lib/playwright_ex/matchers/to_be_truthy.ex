defmodule PlaywrightEx.Matchers.ToBeTruthy do
  @upstream "packages/playwright/src/matchers/toBeTruthy.ts"
  @moduledoc """
  Port of `#{@upstream}`. `this` is the matcher state (`PlaywrightEx.Matchers.Expect`);
  `query` takes `(isNot, timeout)` (no AbortSignal).
  """

  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Matchers.MatcherHint

  def to_be_truthy(this, matcher_name, locator, receiver_type, expected, arg, query, options \\ %{}) do
    options = options || %{}
    MatcherHint.expect_types(locator, [receiver_type], matcher_name)

    timeout = if options[:timeout] == nil, do: this.timeout, else: options.timeout

    %{matches: pass} = result = query.(!!this.isNot, timeout)
    %{log: log, timedOut: timed_out, received: received, errorMessage: error_message} = expect_result(result)
    received_value = received[:value]

    if pass == !this.isNot do
      %{name: matcher_name, message: fn -> "" end, pass: pass, expected: expected}
    else
      {printed_expected, printed_received} =
        if pass,
          do: {"Expected: not #{expected}", if(error_message, do: "", else: "Received: #{expected}")},
          else: {"Expected: #{expected}", if(error_message, do: "", else: "Received: #{js_string(received_value)}")}

      message = fn ->
        MatcherHint.format_matcher_message(this.utils, %{
          isNot: this.isNot,
          promise: this.promise,
          matcherName: matcher_name,
          expectation: arg,
          locator: Locator.to_string(locator),
          timeout: timeout,
          timedOut: timed_out,
          printedExpected: printed_expected,
          printedReceived: printed_received,
          errorMessage: error_message,
          log: log
        })
      end

      %{
        message: message,
        pass: pass,
        actual: received_value,
        name: matcher_name,
        expected: expected,
        log: log,
        timeout: if(timed_out, do: timeout),
        ariaSnapshot: received[:ariaSnapshot]
      }
    end
  end

  # The optional fields of an `ExpectResult`.
  defp expect_result(result), do: Map.merge(%{log: nil, timedOut: nil, received: nil, errorMessage: nil}, result)

  # JS template string interpolation of a received value.
  defp js_string(nil), do: "undefined"
  defp js_string(:null), do: "null"
  defp js_string(value) when is_binary(value), do: value
  defp js_string(value), do: to_string(value)
end
