# upstream: packages/playwright/src/matchers/matcherHint.ts
defmodule PlaywrightJS.Matchers.MatcherHint do
  # upstream: matcherHint.ts:46
  defmodule ExpectError do
    defexception [:message, :matcherResult]

    # upstream: matcherHint.ts:49
    def new(matcher_result, custom_message, _stack_frames) do
      message = matcher_result.message
      message = if custom_message && custom_message != "", do: custom_message <> "\n\n" <> message, else: message
      # this.stack = ...  -- not ported: stack rewriting
      %__MODULE__{message: message, matcherResult: matcher_result}
    end
  end

  # upstream: matcherHint.ts:59
  def expect_types(receiver, types, matcher_name) do
    api_name = if is_struct(receiver), do: receiver.__struct__ |> Module.split() |> List.last()

    if api_name not in types do
      receiver_string = inspect(receiver)
      {comma_separated, [last_type]} = Enum.split(types, -1)
      types_string = if comma_separated != [], do: Enum.join(comma_separated, ", ") <> " or " <> last_type, else: last_type

      raise "#{matcher_name} can be only used with #{types_string} object#{if length(types) > 1, do: "s", else: ""}, was called with #{receiver_string}"
    end
  end

  # upstream: matcherHint.ts:90
  defp print_substring(val), do: String.replace(val, ~r/"|\\/, "\\\\\\0")

  # upstream: matcherHint.ts:92
  def print_received_string_contain_expected_substring(utils, received, start, length) do
    utils.received_color.(
      "\"" <>
        print_substring(String.slice(received, 0, start)) <>
        utils.inverted_color.(print_substring(String.slice(received, start, length))) <>
        print_substring(String.slice(received, (start + length)..-1//1)) <>
        "\""
    )
  end

  # upstream: matcherHint.ts:106
  def print_received_string_contain_expected_result(utils, received, result) do
    case result do
      nil -> utils.print_received.(received)
      [{index, length} | _] -> print_received_string_contain_expected_substring(utils, received, index, length)
    end
  end

  # upstream: matcherHint.ts:138
  def format_matcher_message(utils, details) do
    receiver = details[:receiver] || if(details[:locator], do: "locator", else: "page")

    message =
      utils.dim_color.("expect(") <>
        utils.received_color.(receiver) <>
        utils.dim_color.(
          ")" <>
            if(details[:promise] not in [nil, ""], do: "." <> details.promise, else: "") <> if(details[:isNot], do: ".not", else: "") <> "."
        ) <>
        details.matcherName <>
        utils.dim_color.("(") <> utils.expected_color.(details.expectation) <> utils.dim_color.(")") <> " failed\n\n"

    # Sometimes diff is actually expected + received. Turn it into two lines to
    # simplify alignment logic.
    diff_lines = details[:printedDiff] && String.split(details.printedDiff, "\n")

    details =
      if diff_lines && length(diff_lines) == 2,
        do: Map.merge(details, %{printedExpected: Enum.at(diff_lines, 0), printedReceived: Enum.at(diff_lines, 1), printedDiff: nil}),
        else: details

    align =
      !details[:errorMessage] && details[:printedExpected] && String.starts_with?(details.printedExpected, "Expected:") &&
        (!details[:printedReceived] || String.starts_with?(details.printedReceived, "Received:"))

    message = if details[:locator], do: message <> "Locator: #{if align, do: " ", else: ""}#{details.locator}\n", else: message
    message = if details[:printedExpected], do: message <> details.printedExpected <> "\n", else: message
    message = if details[:printedReceived] not in [nil, ""], do: message <> details.printedReceived <> "\n", else: message

    message =
      if details[:timedOut] && details[:timeout],
        do: message <> "Timeout: #{if align, do: " ", else: ""}#{details.timeout}ms\n",
        else: message

    message = if details[:printedDiff], do: message <> details.printedDiff <> "\n", else: message

    message =
      if details[:errorMessage] do
        message = message <> details.errorMessage
        if !String.ends_with?(details.errorMessage, "\n"), do: message <> "\n", else: message
      else
        message
      end

    message <> call_log_text(utils, details[:log])
  end

  # upstream: matcherHint.ts:176
  def call_log_text(utils, log) do
    if !log || !Enum.any?(log, &(&1 != "")), do: "", else: "\nCall log:\n#{utils.dim_color.(Enum.join(log, "\n"))}\n"
  end
end
