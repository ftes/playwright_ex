# upstream: packages/playwright/src/matchers/toMatchText.ts
defmodule PlaywrightJS.Matchers.ToMatchText do
  import PlaywrightJS.Matchers.MatcherHint

  # upstream: toMatchText.ts:24
  def to_match_text(this, matcher_name, receiver, receiver_type, query, expected, options \\ %{}) do
    expect_types(receiver, [receiver_type], matcher_name)
    locator = if receiver_type == "Locator", do: receiver, else: nil

    if !is_binary(expected) and !is_struct(expected, Regex) do
      error_message =
        "Error: #{this.utils.expected_color.("expected")} value must be a string or regular expression\n#{this.utils.print_expected.(expected)}"

      raise format_matcher_message(this.utils, %{
              promise: this.promise,
              isNot: this.isNot,
              locator: locator && PlaywrightJS.Client.Locator.to_string(locator),
              matcherName: matcher_name,
              expectation: "expected",
              errorMessage: error_message
            })
    end

    timeout = options[:timeout] || this.timeout

    %{matches: pass} = result = query.(!!this.isNot, timeout, options[:signal])

    %{received: received, log: log, timedOut: timed_out, errorMessage: error_message} =
      Map.merge(%{log: nil, timedOut: nil, received: nil, errorMessage: nil}, result)

    if pass == !this.isNot do
      %{name: matcher_name, message: fn -> "" end, pass: pass, expected: expected}
    else
      expected_suffix = if is_binary(expected), do: if(options[:matchSubstring], do: " substring", else: ""), else: " pattern"
      received_suffix = if is_binary(expected), do: if(options[:matchSubstring], do: " string", else: ""), else: " string"
      received_value = received[:value]
      received_string = received_value || ""

      {printed_expected, printed_received, printed_diff} =
        if pass do
          if is_binary(expected) do
            printed_expected = "Expected#{expected_suffix}: not #{this.utils.print_expected.(expected)}"

            printed_received =
              if !error_message do
                {index, _} = :binary.match(received_string, expected)

                formatted_received =
                  print_received_string_contain_expected_substring(this.utils, received_string, index, String.length(expected))

                "Received#{received_suffix}: #{formatted_received}"
              end

            {printed_expected, printed_received, nil}
          else
            printed_expected = "Expected#{expected_suffix}: not #{this.utils.print_expected.(expected)}"

            printed_received =
              if !error_message do
                formatted_received =
                  print_received_string_contain_expected_result(
                    this.utils,
                    received_string,
                    Regex.run(expected, received_string, return: :index)
                  )

                "Received#{received_suffix}: #{formatted_received}"
              end

            {printed_expected, printed_received, nil}
          end
        else
          if error_message,
            do: {"Expected#{expected_suffix}: #{this.utils.print_expected.(expected)}", nil, nil},
            else:
              {nil, nil,
               this.utils.print_diff_or_stringify.(
                 expected,
                 received_string,
                 "Expected#{expected_suffix}",
                 "Received#{received_suffix}",
                 false
               )}
        end

      message = fn ->
        format_matcher_message(this.utils, %{
          promise: this.promise,
          isNot: this.isNot,
          matcherName: matcher_name,
          expectation: "expected",
          locator: locator && PlaywrightJS.Client.Locator.to_string(locator),
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
end
