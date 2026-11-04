defmodule PlaywrightJS.Runtime.Zones do
  @moduledoc """
  Port of `utils/zones.ts` (AsyncLocalStorage). Zones become process-dictionary entries:
  ported async functions run (and await) in a single process, so per-process storage
  has the same scoping as an async context.
  """

  # currentZone().data(type)
  def data(type), do: Map.get(Process.get(:playwright_js_zone, %{}), type)

  # currentZone().with(type, data).run(func)
  def with(type, data, func) do
    previous = Process.get(:playwright_js_zone, %{})
    Process.put(:playwright_js_zone, Map.put(previous, type, data))

    try do
      func.()
    after
      Process.put(:playwright_js_zone, previous)
    end
  end

  # Zone data objects are mutable in JS (e.g. `apiZone.reported = true`).
  def update(type, fun) do
    zone = Process.get(:playwright_js_zone, %{})
    if Map.has_key?(zone, type), do: Process.put(:playwright_js_zone, Map.update!(zone, type, fun))
    data(type)
  end
end
