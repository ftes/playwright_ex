defmodule PlaywrightEx.Matchers.ToMatchText do
  @upstream "packages/playwright/src/matchers/toMatchText.ts"
  @moduledoc """
  Port of `#{@upstream}`. `this` is the matcher state (`PlaywrightEx.Matchers.Expect`);
  `query` takes `(isNot, timeout, signal)`. `RegExp` is a `Regex` or a `PlaywrightEx.RegExp`
  (matched here for the message only when PCRE can run it).
  """

  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Matchers.MatcherHint

  def to_match_text(this, matcher_name, receiver, receiver_type, query, expected, options \\ %{}) do
    options = options || %{}
    MatcherHint.expect_types(receiver, [receiver_type], matcher_name)
    locator = if receiver_type == "Locator", do: receiver

    if not is_binary(expected) and not PlaywrightEx.RegExp.reg_exp?(expected) do
      error_message =
        "Error: #{this.utils.expected_color("expected")} value must be a string or regular expression\n#{this.utils.print_with_type("Expected", expected, &this.utils.print_expected(&1))}"

      raise MatcherHint.format_matcher_message(this.utils, %{
              promise: this.promise,
              isNot: this.isNot,
              locator: locator && Locator.to_string(locator),
              matcherName: matcher_name,
              expectation: "expected",
              errorMessage: error_message
            })
    end

    timeout = if options[:timeout] == nil, do: this.timeout, else: options.timeout

    %{matches: pass} = result = query.(!!this.isNot, timeout, options[:signal])

    %{received: received, log: log, timedOut: timed_out, errorMessage: error_message} =
      Map.merge(%{log: nil, timedOut: nil, received: nil, errorMessage: nil}, result)

    if pass == !this.isNot do
      %{name: matcher_name, message: fn -> "" end, pass: pass, expected: expected}
    else
      expected_suffix =
        if is_binary(expected), do: if(options[:matchSubstring], do: " substring", else: ""), else: " pattern"

      received_suffix =
        if is_binary(expected), do: if(options[:matchSubstring], do: " string", else: ""), else: " string"

      received_value = received[:value]
      # `receivedValue || ''`: also for a JS `null`.
      received_string = if received_value in [nil, :null], do: "", else: received_value

      {printed_expected, printed_received, printed_diff} =
        cond do
          pass and is_binary(expected) ->
            printed_expected = "Expected#{expected_suffix}: not #{this.utils.print_expected(expected)}"

            printed_received =
              if !error_message do
                formatted_received =
                  MatcherHint.print_received_string_contain_expected_substring(
                    this.utils,
                    received_string,
                    index_of(received_string, expected),
                    String.length(expected)
                  )

                "Received#{received_suffix}: #{formatted_received}"
              end

            {printed_expected, printed_received, nil}

          pass ->
            printed_expected = "Expected#{expected_suffix}: not #{this.utils.print_expected(expected)}"

            printed_received =
              if !error_message do
                formatted_received =
                  MatcherHint.print_received_string_contain_expected_result(
                    this.utils,
                    received_string,
                    PlaywrightEx.RegExp.exec_index(expected, received_string)
                  )

                "Received#{received_suffix}: #{formatted_received}"
              end

            {printed_expected, printed_received, nil}

          error_message ->
            {"Expected#{expected_suffix}: #{this.utils.print_expected(expected)}", nil, nil}

          true ->
            {nil, nil,
             this.utils.print_diff_or_stringify(
               expected,
               received_string,
               "Expected#{expected_suffix}",
               "Received#{received_suffix}",
               false
             )}
        end

      message = fn ->
        MatcherHint.format_matcher_message(this.utils, %{
          promise: this.promise,
          isNot: this.isNot,
          matcherName: matcher_name,
          expectation: "expected",
          locator: locator && Locator.to_string(locator),
          timeout: timeout,
          timedOut: timed_out,
          printedExpected: printed_expected,
          printedReceived: printed_received,
          printedDiff: printed_diff,
          log: log,
          errorMessage: error_message
        })
      end

      %{
        name: matcher_name,
        expected: expected,
        message: message,
        pass: pass,
        actual: received_value,
        log: log,
        timeout: if(timed_out, do: timeout),
        ariaSnapshot: received[:ariaSnapshot]
      }
    end
  end

  # `string.indexOf(search)` in characters, -1 when absent.
  defp index_of(_string, ""), do: 0

  defp index_of(string, search) do
    case :binary.match(string, search) do
      {byte, _} -> String.length(binary_part(string, 0, byte))
      :nomatch -> -1
    end
  end
end
