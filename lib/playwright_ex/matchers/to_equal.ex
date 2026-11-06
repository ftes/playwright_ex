defmodule PlaywrightEx.Matchers.ToEqual do
  @upstream "packages/playwright/src/matchers/toEqual.ts"
  @moduledoc """
  Port of `#{@upstream}`. `this` is the matcher state (`PlaywrightEx.Matchers.Expect`);
  `query` takes `(isNot, timeout, signal)`.
  """

  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Matchers.MatcherHint

  # Omit colon and one or more spaces, so can call getLabelPrinter.
  @expected_label "Expected"
  @received_label "Received"

  def to_equal(this, matcher_name, locator, receiver_type, query, expected, options \\ %{}) do
    options = options || %{}
    MatcherHint.expect_types(locator, [receiver_type], matcher_name)

    timeout = if options[:timeout] == nil, do: this.timeout, else: options.timeout

    %{matches: pass} = result = query.(!!this.isNot, timeout, options[:signal])

    %{received: received, log: log, timedOut: timed_out, errorMessage: error_message} =
      Map.merge(%{log: nil, timedOut: nil, received: nil, errorMessage: nil}, result)

    received_value = received[:value]

    if pass == !this.isNot do
      %{name: matcher_name, message: fn -> "" end, pass: pass, expected: expected}
    else
      {printed_expected, printed_received, printed_diff} =
        cond do
          pass ->
            {"Expected: not #{this.utils.print_expected(expected)}",
             if(error_message, do: "", else: "Received: #{this.utils.print_received(received_value)}"), nil}

          error_message ->
            {"Expected: #{this.utils.print_expected(expected)}", nil, nil}

          is_list(expected) and is_list(received_value) ->
            normalized_expected =
              expected
              |> Enum.with_index()
              |> Enum.map(fn {exp, index} ->
                rec = Enum.at(received_value, index)

                if PlaywrightEx.RegExp.reg_exp?(exp),
                  do: if(PlaywrightEx.RegExp.exec_index(exp, js_string(rec)), do: rec, else: exp),
                  else: exp
              end)

            {nil, nil,
             this.utils.print_diff_or_stringify(
               normalized_expected,
               received_value,
               @expected_label,
               @received_label,
               false
             )}

          true ->
            {nil, nil,
             this.utils.print_diff_or_stringify(
               expected,
               received_value,
               @expected_label,
               @received_label,
               false
             )}
        end

      message = fn ->
        MatcherHint.format_matcher_message(this.utils, %{
          isNot: this.isNot,
          promise: this.promise,
          matcherName: matcher_name,
          expectation: "expected",
          locator: Locator.to_string(locator),
          timeout: timeout,
          timedOut: timed_out,
          printedExpected: printed_expected,
          printedReceived: printed_received,
          printedDiff: printed_diff,
          errorMessage: error_message,
          log: log
        })
      end

      # Passing the actual and expected objects so that a custom reporter
      # could access them, for example in order to display a custom visual diff,
      # or create a different error message
      %{
        actual: received_value,
        expected: expected,
        message: message,
        name: matcher_name,
        pass: pass,
        log: log,
        timeout: if(timed_out, do: timeout),
        ariaSnapshot: received[:ariaSnapshot]
      }
    end
  end

  # `regex.test(value)` converts the value to a string.
  defp js_string(nil), do: "undefined"
  defp js_string(value) when is_binary(value), do: value
  defp js_string(value), do: to_string(value)
end
