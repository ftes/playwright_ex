defmodule PlaywrightEx.AbortController do
  @moduledoc """
  The DOM `AbortController`: aborts the calls given its `signal/1` as `signal:` option.

      controller = PlaywrightEx.AbortController.new()
      signal = PlaywrightEx.AbortController.signal(controller)
      Task.start(fn -> Process.sleep(1000); PlaywrightEx.AbortController.abort(controller) end)
      {:error, %PlaywrightEx.AbortError{}} = PlaywrightEx.Locator.click(button, signal: signal, timeout: 0)

  Any process can abort. The calls fail with `PlaywrightEx.AbortError`, whose
  `cause` is the reason; matchers fail like a timeout ("The assertion was aborted").

  Runtime support (not ported from upstream). Deviation: a controller belongs to one driver
  (its event loop), see `new/1`.
  """
  alias PlaywrightEx.AbortError
  alias PlaywrightEx.AbortSignal
  alias PlaywrightEx.Runtime.EventLoop

  defstruct [:signal]

  @typedoc "An abort controller."
  @type t :: %__MODULE__{signal: AbortSignal.t()}

  @doc """
  `new AbortController()`. The signal lives in the event loop of a driver: `driver` is a handle
  of it (a page, locator, ...) or the name of its `PlaywrightEx.Supervisor`. By default, the
  driver of the calling Playwright callback, else the one named `PlaywrightEx`.
  """
  @spec new(atom() | map() | nil) :: t()
  def new(driver \\ nil) do
    loop =
      cond do
        driver == nil and EventLoop.held?() -> EventLoop.current!()
        is_atom(driver) -> EventLoop.get(Module.concat(driver || PlaywrightEx, EventLoop))
        loop = EventLoop.find(driver) -> loop
        true -> raise ArgumentError, "not a Playwright handle: #{inspect(driver)}"
      end

    EventLoop.with_baton(loop, fn -> %__MODULE__{signal: AbortSignal.new()} end)
  end

  @doc "`controller.signal`."
  @spec signal(t()) :: AbortSignal.t()
  def signal(%__MODULE__{signal: signal}), do: signal

  @doc """
  `controller.abort(reason)`: aborts the signal, from any process. Without a reason (`nil`), the
  reason is an `AbortError` "This operation was aborted" (JS: a `DOMException` of that name).
  Aborting twice does nothing.
  """
  @spec abort(t(), term()) :: :ok
  def abort(%__MODULE__{signal: signal}, reason \\ nil) do
    reason = if reason == nil, do: %AbortError{message: "This operation was aborted"}, else: reason
    EventLoop.with_baton(signal.loop, fn -> AbortSignal.signal_abort(signal, reason) end)
  end
end
