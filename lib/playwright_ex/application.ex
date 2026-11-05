defmodule PlaywrightEx.Application do
  @moduledoc false
  # Global state of the library: the table of the abort signals (`PlaywrightEx.AbortSignal`).
  # Drivers are started by the user (`PlaywrightEx.Supervisor`).
  use Application

  @impl Application
  def start(_type, _args) do
    children = [%{id: PlaywrightEx.AbortSignal, start: {Agent, :start_link, [&PlaywrightEx.AbortSignal.new_table/0]}}]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
