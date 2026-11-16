defmodule Playwright.AbortController do
  @moduledoc """
  The DOM `AbortController`: aborts the calls given its `signal/1` as `signal:` option.

      controller = Playwright.AbortController.new()
      signal = Playwright.AbortController.signal(controller)
      Task.start(fn -> Process.sleep(1000); Playwright.AbortController.abort(controller) end)
      {:error, %Playwright.AbortError{}} = Playwright.Locator.click(button, signal: signal, timeout: 0)

  Any process can abort. The calls fail with `Playwright.AbortError`, whose
  `cause` is the reason; matchers fail like a timeout ("The assertion was aborted").

  Runtime support (not ported from upstream). A controller is global, as in JS: its signal works
  with calls on any driver (see `Playwright.AbortSignal`).
  """
  alias Playwright.AbortError
  alias Playwright.AbortSignal

  defstruct [:signal]

  @typedoc "An abort controller."
  @type t :: %__MODULE__{signal: AbortSignal.t()}

  @doc "`new AbortController()`."
  @spec new() :: t()
  def new, do: %__MODULE__{signal: AbortSignal.new()}

  @doc "`controller.signal`."
  @spec signal(t()) :: AbortSignal.t()
  def signal(%__MODULE__{signal: signal}), do: signal

  @doc """
  `controller.abort(reason)`: aborts the signal, from any process; its listeners have run when it
  returns (see `Playwright.AbortSignal`). Without a reason
  (`nil`), the reason is an `AbortError` "This operation was aborted" (JS: a `DOMException` of that
  name). Aborting twice does nothing.
  """
  @spec abort(t(), term()) :: :ok
  def abort(%__MODULE__{signal: signal}, reason \\ nil) do
    reason = if reason == nil, do: %AbortError{message: "This operation was aborted"}, else: reason
    AbortSignal.signal_abort(signal, reason)
  end
end
