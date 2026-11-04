defmodule PlaywrightEx.Matchers.MatcherHint do
  @upstream "packages/playwright/src/matchers/matcherHint.ts"
  @moduledoc """
  Port of `#{@upstream}`. `utils` is `PlaywrightEx.Matchers.MatcherUtils` (jest-matcher-utils).
  A `MatcherResult` is a map with the JS keys; its `message` is a function until `ExpectError`
  stores the rendered string.
  """

  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Runtime.Heap

  defmodule ExpectError do
    @moduledoc """
    JS `ExpectError`: a failed matcher (`PlaywrightEx.Expect`). `matcherResult` mirrors JS: a map
    with `name`, `message`, `pass`, `expected`, `actual`, `log`, `timeout`, `ariaSnapshot` (keys
    whose JS value is `undefined` are left out).
    """
    defexception message: "", name: "Error", matcherResult: nil, stack: ""

    def new(matcher_result, custom_message, _stack_frames) do
      message = matcher_result.message
      message = if custom_message not in [nil, ""], do: custom_message <> "\n\n" <> message, else: message

      # this.stack = this.name + ': ' + this.message + '\n' + stringifyStackFrames(stackFrames).join('\n');  -- not ported: Elixir stack traces
      %__MODULE__{message: message, matcherResult: matcher_result}
    end
  end

  def expect_types(receiver, types, matcher_name) do
    if receiver_api_name(receiver) not in types do
      receiver_string =
        if is_struct(receiver),
          do: "#{receiver.__struct__ |> Module.split() |> List.last()} #{inspect(receiver)}",
          else: js_string(receiver)

      {comma_separated, [last_type]} = Enum.split(types, -1)

      types_string =
        if comma_separated != [], do: Enum.join(comma_separated, ", ") <> " or " <> last_type, else: last_type

      raise "#{matcher_name} can be only used with #{types_string} object#{if length(types) > 1, do: "s"}, was called with #{receiver_string}"
    end
  end

  # `receiver._apiName`: a struct field of value objects (Locator), a heap field of channel owners (Page).
  defp receiver_api_name(%{_apiName: api_name}), do: api_name

  defp receiver_api_name(receiver) do
    if ChannelOwner.is_channel_owner(receiver), do: Heap.get(receiver, :_apiName)
  end

  # region
  # Mirrored from https://github.com/facebook/jest/blob/f13abff8df9a0e1148baf3584bcde6d1b479edc7/packages/expect/src/print.ts with minor modifications.

  # Format substring but do not enclose in double quote marks.
  # The replacement is compatible with pretty-format package.
  defp print_substring(val), do: String.replace(val, ~r/"|\\/, "\\\\\\0")

  # `start`, `length` count characters (UTF-16 code units in JS).
  def print_received_string_contain_expected_substring(utils, received, start, length) do
    utils.received_color(
      ~s(") <>
        print_substring(js_slice(received, 0, start)) <>
        utils.inverted_color(print_substring(js_slice(received, start, start + length))) <>
        print_substring(js_slice(received, start + length)) <>
        ~s(")
    )
  end

  # `result`: `[{index, length}]` as `Regex.run(re, s, return: :index)` gives it (`RegExpExecArray`), or nil.
  def print_received_string_contain_expected_result(utils, received, result) do
    case result do
      nil ->
        utils.print_received(received)

      [{index, length} | _] ->
        # Byte offsets from Regex.run: as characters for print_received_string_contain_expected_substring.
        start = String.length(binary_part(received, 0, index))
        length = String.length(binary_part(received, index, length))
        print_received_string_contain_expected_substring(utils, received, start, length)
    end
  end

  # endregion

  def format_matcher_message(utils, details) do
    receiver = details[:receiver] || if(details[:locator], do: "locator", else: "page")

    message =
      utils.dim_color("expect(") <>
        utils.received_color(receiver) <>
        utils.dim_color(
          ")" <>
            if(details[:promise] not in [nil, ""], do: "." <> details.promise, else: "") <>
            if(details[:isNot], do: ".not", else: "") <> "."
        ) <>
        details.matcherName <>
        utils.dim_color("(") <>
        utils.expected_color(details.expectation) <> utils.dim_color(")") <> " failed\n\n"

    # Sometimes diff is actually expected + received. Turn it into two lines to
    # simplify alignment logic.
    diff_lines = if details[:printedDiff], do: String.split(details.printedDiff, "\n")

    details =
      case diff_lines do
        [printed_expected, printed_received] ->
          Map.merge(details, %{printedExpected: printed_expected, printedReceived: printed_received, printedDiff: nil})

        _ ->
          details
      end

    align =
      !details[:errorMessage] and is_binary(details[:printedExpected]) and
        String.starts_with?(details.printedExpected, "Expected:") and
        (!details[:printedReceived] or String.starts_with?(details.printedReceived, "Received:"))

    pad = if align, do: " ", else: ""
    message = if details[:locator], do: message <> "Locator: #{pad}#{details.locator}\n", else: message
    message = if truthy(details[:printedExpected]), do: message <> details.printedExpected <> "\n", else: message
    message = if truthy(details[:printedReceived]), do: message <> details.printedReceived <> "\n", else: message

    message =
      if details[:timedOut] && truthy(details[:timeout]),
        do: message <> "Timeout: #{pad}#{details.timeout}ms\n",
        else: message

    message = if truthy(details[:printedDiff]), do: message <> details.printedDiff <> "\n", else: message

    message =
      if truthy(details[:errorMessage]) do
        message = message <> details.errorMessage
        if !String.ends_with?(details.errorMessage, "\n"), do: message <> "\n", else: message
      else
        message
      end

    message <> call_log_text(utils, details[:log])
  end

  def call_log_text(utils, log) do
    if !log or !Enum.any?(log, &truthy/1) do
      ""
    else
      """

      Call log:
      #{utils.dim_color(Enum.join(log, "\n"))}
      """
    end
  end

  # JS `string.slice(start, end)`: negative indices count from the end.
  defp js_slice(string, start, finish \\ nil) do
    n = String.length(string)
    index = fn i -> if i < 0, do: max(n + i, 0), else: min(i, n) end
    from = index.(start)
    to = if finish == nil, do: n, else: index.(finish)
    if to > from, do: String.slice(string, from, to - from), else: ""
  end

  # JS truthiness of strings and numbers.
  defp truthy(value), do: value not in [nil, false, "", 0]

  # JS `String(value)`.
  defp js_string(nil), do: "undefined"
  defp js_string(:null), do: "null"
  defp js_string(value) when is_binary(value), do: value
  defp js_string(value), do: inspect(value)
end
