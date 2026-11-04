# upstream: packages/playwright-core/src/client/errors.ts
defmodule PlaywrightJS.Client.Errors do
  # upstream: errors.ts:22
  defmodule PlaywrightError do
    defexception message: "", name: "Error", log: [], details: nil, stack: "", code: nil, cause: nil
  end

  # upstream: errors.ts:27
  defmodule TimeoutError do
    defexception message: "", name: "TimeoutError", log: [], details: nil, stack: "", code: nil, cause: nil
  end

  # upstream: errors.ts:34
  defmodule TargetClosedError do
    defexception message: "Target page, context or browser has been closed",
                 name: "Error",
                 log: [],
                 details: nil,
                 stack: "",
                 code: nil,
                 cause: nil

    # upstream: errors.ts:35
    def new(cause \\ nil), do: %__MODULE__{message: cause || "Target page, context or browser has been closed"}
  end

  # upstream: errors.ts:41
  defmodule AbortError do
    defexception message: "The operation was aborted", name: "AbortError", log: [], details: nil, stack: "", code: nil, cause: nil
  end

  # `e instanceof PlaywrightError` (class hierarchy flattened into a membership test)
  def is_playwright_error(e),
    do: is_struct(e, PlaywrightError) or is_struct(e, TimeoutError) or is_struct(e, TargetClosedError) or is_struct(e, AbortError)

  # upstream: errors.ts:48
  def is_target_closed_error(error) do
    is_struct(error, TargetClosedError)
  end

  # upstream: errors.ts:58
  def parse_error(error) do
    if !error[:error] do
      if error[:value] == nil, do: raise("Serialized error must have either an error or a value")
      PlaywrightJS.Protocol.Serializers.parse_serialized_value(error.value, nil)
    else
      e =
        cond do
          error.error[:name] == "TimeoutError" -> %TimeoutError{message: error.error.message}
          error.error[:name] == "TargetClosedError" -> TargetClosedError.new(error.error.message)
          error.error[:name] == "AbortError" -> %AbortError{message: error.error.message}
          true -> %PlaywrightError{message: error.error.message, name: error.error[:name]}
        end

      e = %{e | stack: error.error[:stack] || ""}
      e = if error.error[:code] != nil, do: %{e | code: error.error.code}, else: e
      e
    end
  end

  # rewriteErrorMessage(e, message) from utils/stackTrace.ts (exceptions are immutable)
  def rewrite_error_message(%{message: _} = e, message), do: %{e | message: message}
  def rewrite_error_message(e, _message), do: e
end
