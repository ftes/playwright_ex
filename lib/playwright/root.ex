defmodule Playwright.Root do
  @moduledoc false
  # The hand-written part of the root module `Playwright`, whose facade (upstream's `Playwright`
  # class, as `require('playwright')` is the Playwright object) `mix playwright.gen.api`
  # generates with `use Playwright.Root`. Its moduledoc's introduction is in
  # `Mix.Playwright.ApiRules`.

  defmacro __using__(_opts) do
    quote do
      @typedoc """
      An error a call fails with: the tuple forms return `{:error, error}`, the bang forms raise it.
      These are what a JS call rejects with: Playwright's errors (`Playwright.PlaywrightError` for
      JS `Error`, `Playwright.TimeoutError`, `Playwright.TargetClosedError`,
      `Playwright.AbortError`, the matchers' `Playwright.ExpectError`), and what the client
      throws itself: `RuntimeError` for a JS `new Error(message)` ("Route is already handled!"), the
      protocol's `ValidationError` for an argument of the wrong type, `JSON.DecodeError` where JS's
      `JSON.parse` fails and `File.Error` for local files. Anything else (`ArgumentError` for an
      unknown option, a `FunctionClauseError`) is a bug or a misuse and raises in both forms.
      """
      @type error ::
              Playwright.PlaywrightError.t()
              | Playwright.TimeoutError.t()
              | Playwright.TargetClosedError.t()
              | Playwright.AbortError.t()
              | Playwright.ExpectError.t()
              | %RuntimeError{}
              | %Playwright.Protocol.ValidatorPrimitives.ValidationError{}
              | %JSON.DecodeError{}
              | %File.Error{}

      @doc """
      The root `Playwright` object of the driver started as `name`.

      While a lost driver is being replaced (see `Playwright.Supervisor`), this waits for the new
      driver and returns its root, also when called from a `disconnected` listener. It exits if the
      supervisor is not running, or not restarting the driver.
      """
      @spec instance(atom()) :: t()
      def instance(name \\ __MODULE__) do
        # An await: in a listener, the connection goes on (a lost driver's close emulation finishes).
        Playwright.Runtime.Invocation.yield()
        Playwright.Supervisor.playwright(name)
      end
    end
  end
end
