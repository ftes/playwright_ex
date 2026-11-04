defmodule Playwright.Application do
  # Not ported (no upstream counterpart): owns the ETS "heap" that backs mutable Java object fields.
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Playwright.Impl.Heap], strategy: :one_for_one, name: Playwright.Supervisor)
  end
end
