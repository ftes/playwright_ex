defmodule PlaywrightEx do
  @moduledoc """
  Elixir client for Playwright, ported 1:1 from the official JavaScript client.

  Start a driver with `PlaywrightEx.Supervisor`, then get the root object:

      {:ok, _} = PlaywrightEx.Supervisor.start_link()
      playwright = PlaywrightEx.playwright()

  The generated public API is not there yet; until then, `PlaywrightEx.Client.*` is the
  ported client and `PlaywrightEx.Runtime.Api.call/3` the entry point for calls into it.
  """

  @doc "The root `Playwright` object of the driver started as `name`."
  def playwright(name \\ __MODULE__),
    do: PlaywrightEx.OutOfProcess.playwright(PlaywrightEx.Supervisor.out_of_process(name))
end
