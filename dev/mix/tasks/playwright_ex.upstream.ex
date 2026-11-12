defmodule Mix.Tasks.PlaywrightEx.Upstream do
  @shortdoc "Downloads the upstream sources at the pin and prints their directory"
  @moduledoc """
  Usage: `mix playwright_ex.upstream`

  Runs `PlaywrightEx.Upstream.ensure!/0` and prints the directory: upstream's client, server,
  injected script, specs and API docs at the pinned `PlaywrightEx.Driver.version/0`, to read
  alongside the port.
  """
  use Mix.Task

  @impl true
  def run([]), do: Mix.shell().info(PlaywrightEx.Upstream.ensure!())
end
