defmodule PlaywrightEx.Supervisor do
  @moduledoc """
  Playwright connection supervision tree.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init([]) do
    children = [PlaywrightEx.PortServer, PlaywrightEx.Connection]
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
