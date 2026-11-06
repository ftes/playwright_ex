defmodule PlaywrightEx.ExpectError do
  @moduledoc """
  JS `ExpectError` (`packages/playwright/src/matchers/matcherHint.ts`): a failed matcher
  (`PlaywrightEx.Expect`). `matcherResult` mirrors JS: a map with `name`, `message`, `pass`,
  `expected`, `actual`, `log`, `timeout`, `ariaSnapshot` (keys whose JS value is `undefined` are
  left out).
  """
  @type t :: %__MODULE__{message: String.t(), name: String.t(), matcherResult: map() | nil, stack: String.t()}

  defexception message: "", name: "Error", matcherResult: nil, stack: ""

  @doc false
  # `new ExpectError(matcherResult, customMessage, stackFrames)`, for the matchers.
  def new(matcher_result, custom_message, _stack_frames) do
    message = matcher_result.message
    message = if custom_message in [nil, ""], do: message, else: custom_message <> "\n\n" <> message

    # this.stack = this.name + ': ' + this.message + '\n' + stringifyStackFrames(stackFrames).join('\n');  -- not ported: Elixir stack traces
    %__MODULE__{message: message, matcherResult: matcher_result}
  end
end
