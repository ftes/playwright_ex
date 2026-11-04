# upstream: packages/playwright/src/matchers/toBeTruthy.ts
defmodule PlaywrightJS.Matchers.ToBeTruthy do
  import PlaywrightJS.Matchers.MatcherHint, only: [expect_types: 3, format_matcher_message: 2]

  # upstream: toBeTruthy.ts:24
  def to_be_truthy(this, matcher_name, locator, receiver_type, expected, arg, query, options \\ %{}) do
    expect_types(locator, [receiver_type], matcher_name)

    timeout = options[:timeout] || this.timeout

    %{matches: pass} = result = query.(!!this.isNot, timeout, options[:signal])

    %{log: log, timedOut: timed_out, received: received, errorMessage: error_message} =
      Map.merge(%{log: nil, timedOut: nil, received: nil, errorMessage: nil}, result)

    received_value = received[:value]

    if pass == !this.isNot do
      %{name: matcher_name, message: fn -> "" end, pass: pass, expected: expected}
    else
      {printed_expected, printed_received} =
        if pass do
          {"Expected: not #{expected}", if(error_message, do: "", else: "Received: #{expected}")}
        else
          {"Expected: #{expected}", if(error_message, do: "", else: "Received: #{received_value}")}
        end

      message = fn ->
        format_matcher_message(this.utils, %{
          isNot: this.isNot,
          promise: this.promise,
          matcherName: matcher_name,
          expectation: arg,
          locator: PlaywrightJS.Client.Locator.to_string(locator),
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
end
