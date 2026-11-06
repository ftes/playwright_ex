defmodule PlaywrightEx.Application do
  @moduledoc false
  # Global state of the library: the table of the abort signals (`PlaywrightEx.AbortSignal`) and
  # the rows owned by processes (`PlaywrightEx.Runtime.ProcessOwner`). Drivers are started by the
  # user (`PlaywrightEx.Supervisor`).
  use Application

  @impl Application
  def start(_type, _args) do
    # A bad `config :playwright_ex, :expect` fails here, not at the first matcher.
    PlaywrightEx.Matchers.Expect.app_env_expect_config()
    children = [PlaywrightEx.AbortSignal, PlaywrightEx.Runtime.ProcessOwner]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
