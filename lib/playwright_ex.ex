defmodule PlaywrightEx do
  @moduledoc """
  Elixir client for Playwright, ported 1:1 from the official JavaScript client.

  Start a driver with `PlaywrightEx.Supervisor`, then get the root object:

      {:ok, _} = PlaywrightEx.Supervisor.start_link()
      playwright = PlaywrightEx.playwright()
      {:ok, browser} = PlaywrightEx.BrowserType.launch(PlaywrightEx.Playwright.chromium(playwright))
      :ok = PlaywrightEx.Browser.close(browser)

  The public API (`PlaywrightEx.Playwright`, `PlaywrightEx.BrowserType`, ...) is generated from
  upstream's docs, so the docs at playwright.dev apply; the
  [Getting started](getting-started.md) and
  [From playwright.dev to Elixir](api-conventions.md) guides show how. The examples in the
  function docs alias the modules they use (`alias PlaywrightEx.{Locator, Page}`). Coming
  from 0.16: see the [migration guide](migration.md).
  """

  @typedoc """
  An error a call fails with: the tuple forms return `{:error, error}`, the bang forms raise it.
  These are what a JS call rejects with: Playwright's errors (`PlaywrightEx.PlaywrightError` for
  JS `Error`, `PlaywrightEx.TimeoutError`, `PlaywrightEx.TargetClosedError`,
  `PlaywrightEx.AbortError`, the matchers' `PlaywrightEx.ExpectError`), and what the client
  throws itself: `RuntimeError` for a JS `new Error(message)` ("Route is already handled!"), the
  protocol's `ValidationError` for an argument of the wrong type, `JSON.DecodeError` where JS's
  `JSON.parse` fails and `File.Error` for local files. Anything else (`ArgumentError` for an
  unknown option, a `FunctionClauseError`) is a bug or a misuse and raises in both forms.
  """
  @type error ::
          PlaywrightEx.PlaywrightError.t()
          | PlaywrightEx.TimeoutError.t()
          | PlaywrightEx.TargetClosedError.t()
          | PlaywrightEx.AbortError.t()
          | PlaywrightEx.ExpectError.t()
          | %RuntimeError{}
          | %PlaywrightEx.Protocol.ValidatorPrimitives.ValidationError{}
          | %JSON.DecodeError{}
          | %File.Error{}

  @doc """
  The root `PlaywrightEx.Playwright` object of the driver started as `name`.

  While a lost driver is being replaced (see `PlaywrightEx.Supervisor`), this waits for the new
  driver and returns its root, also when called from a `disconnected` listener. It exits if the
  supervisor is not running, or not restarting the driver.
  """
  @spec playwright(atom()) :: PlaywrightEx.Playwright.t()
  def playwright(name \\ __MODULE__) do
    # An await: in a listener, the connection goes on (a lost driver's close emulation finishes).
    PlaywrightEx.Runtime.Invocation.yield()
    PlaywrightEx.Supervisor.playwright(name)
  end
end
