# upstream: playwright/_impl/_errors.py
# Decision: Python's exception hierarchy (TimeoutError(Error), TargetClosedError(Error))
# has no Elixir counterpart (no exception inheritance), so each class is its own
# exception module with identical fields; `isinstance(e, Error)` becomes `is_error(e)`
# / `rescue e in [Error, TimeoutError, TargetClosedError]`.
defmodule Playwright.Impl.Errors do
  alias Playwright.Impl.Errors.{Error, TimeoutError, TargetClosedError}

  @all [Error, TimeoutError, TargetClosedError]
  def all, do: @all

  # isinstance(e, Error)
  def is_error(%mod{}) when mod in @all, do: true
  def is_error(_), do: false

  # upstream: _errors.py:22
  def is_target_closed_error(error), do: match?(%TargetClosedError{}, error)

  # upstream: _errors.py:57
  def rewrite_error(error, message) do
    # type(error)(message) + copying _name/_stack/_details/_log == struct update
    rewritten_exc = if Map.has_key?(error, :message), do: %{error | message: message}, else: error
    rewritten_exc
  end
end

defmodule Playwright.Impl.Errors.Error do
  # upstream: _errors.py:26
  defexception message: nil, _name: nil, _stack: nil, _details: nil, _log: nil
  def new(message), do: %__MODULE__{message: message}
end

defmodule Playwright.Impl.Errors.TimeoutError do
  # upstream: _errors.py:48
  defexception message: nil, _name: nil, _stack: nil, _details: nil, _log: nil
  def new(message), do: %__MODULE__{message: message}
end

defmodule Playwright.Impl.Errors.TargetClosedError do
  # upstream: _errors.py:52
  defexception message: nil, _name: nil, _stack: nil, _details: nil, _log: nil

  def new(message \\ nil),
    do: %__MODULE__{message: message || "Target page, context or browser has been closed"}
end
