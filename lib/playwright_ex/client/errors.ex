defmodule PlaywrightEx.Client.Errors do
  @upstream "packages/playwright-core/src/client/errors.ts"
  @moduledoc """
  Port of `#{@upstream}`. Each JS error class is an exception with the JS fields
  (`name`, `log`, `details`, `stack`, `code`, `cause`); `e instanceof PlaywrightError`
  becomes `is_playwright_error/1`.
  """
  alias PlaywrightEx.Protocol.Serializers

  defmodule PlaywrightError do
    @moduledoc "JS `PlaywrightError` (`name` is `\"Error\"` unless the server says otherwise)."
    defexception message: "", name: "Error", log: [], details: nil, stack: "", code: nil, cause: nil
  end

  defmodule TimeoutError do
    @moduledoc "JS `TimeoutError`."
    defexception message: "", name: "TimeoutError", log: [], details: nil, stack: "", code: nil, cause: nil
  end

  defmodule TargetClosedError do
    @moduledoc "JS `TargetClosedError`."
    defexception message: "Target page, context or browser has been closed",
                 name: "Error",
                 log: [],
                 details: nil,
                 stack: "",
                 code: nil,
                 cause: nil

    def new(cause \\ nil), do: %__MODULE__{message: cause || "Target page, context or browser has been closed"}
  end

  defmodule AbortError do
    @moduledoc "JS `AbortError`."
    defexception message: "The operation was aborted",
                 name: "AbortError",
                 log: [],
                 details: nil,
                 stack: "",
                 code: nil,
                 cause: nil
  end

  # `e instanceof PlaywrightError` (the class hierarchy flattened into a membership test)
  def is_playwright_error(e),
    do:
      is_struct(e, PlaywrightError) or is_struct(e, TimeoutError) or is_target_closed_error(e) or
        is_struct(e, AbortError)

  def is_target_closed_error(error) do
    is_struct(error, TargetClosedError)
  end

  def serialize_error(e) do
    if is_exception(e),
      do: %{
        error: %{
          message: Serializers.system_error_message(e),
          stack: Map.get(e, :stack) || "",
          name: Map.get(e, :name) || inspect(e.__struct__),
          code: Serializers.system_error_code(e)
        }
      },
      else: %{value: Serializers.serialize_value(e, fn value -> %{fallThrough: value} end)}
  end

  def parse_error(error) do
    if !error[:error] do
      if error[:value] == nil, do: raise("Serialized error must have either an error or a value")
      Serializers.parse_serialized_value(error.value, nil)
    else
      e =
        cond do
          error.error[:name] == "TimeoutError" -> %TimeoutError{message: error.error.message}
          error.error[:name] == "TargetClosedError" -> TargetClosedError.new(error.error.message)
          error.error[:name] == "AbortError" -> %AbortError{message: error.error.message}
          true -> %PlaywrightError{message: error.error.message, name: error.error[:name]}
        end

      e = %{e | stack: error.error[:stack] || ""}
      if error.error[:code] != nil, do: %{e | code: error.error.code}, else: e
    end
  end

  # rewriteErrorMessage(e, message) from utils/stackTrace.ts (exceptions are immutable: returns the new error)
  def rewrite_error_message(%{message: _} = e, message), do: %{e | message: message}
  def rewrite_error_message(e, _message), do: e
end
