defmodule Playwright.Test.TimeoutManagerError do
  @moduledoc """
  A test ran past its timeout: "Test timeout of 60000ms exceeded." (see Timeouts in
  `Playwright.Test`). Port of `TimeoutManagerError`
  (`packages/playwright/src/worker/timeoutManager.ts`).

  Elixir only: upstream reports a second error after it, the one the driver call the test hung in
  fails with once teardown closes its context (`page.waitForSelector: Test timeout of 60000ms
  exceeded.` and the call log). Here the test's process exited at the timeout, so the error
  comes after it: the message ends with it once it came. ExUnit formats the failure after the
  test's `on_exit` callbacks, which close the contexts; a failure formatted earlier (or a call
  still running past them) has the timeout's message alone. The error is kept for the run, one
  per timed-out test: a formatter may read the message until the suite ends.
  """
  @typedoc "`message` is the timeout's; `late_error` the key of the call's error."
  @type t :: %__MODULE__{message: String.t(), late_error: reference() | nil}

  defexception message: "", late_error: nil

  alias Playwright.Test.Results

  @impl true
  def message(%__MODULE__{message: message} = error) do
    case late_error(error) do
      nil -> message
      late -> message <> "\n\n" <> Exception.format_banner(:error, late)
    end
  end

  @doc false
  # The call's error, once it came (`put_late_error/2`), or `nil`.
  def late_error(%__MODULE__{late_error: key}) do
    case key && Results.started?() && :ets.lookup(Results.table(), {:late_error, key}) do
      [{_key, error}] -> error
      _ -> nil
    end
  end

  @doc false
  # Notes `late`, the error of the call the test hung in: the first one is kept. It stays for
  # the run, for any formatter, as ExUnit's failures do.
  def put_late_error(%__MODULE__{late_error: key}, late) do
    if Results.started?(), do: :ets.insert_new(Results.table(), {{:late_error, key}, late})
    :ok
  end
end
