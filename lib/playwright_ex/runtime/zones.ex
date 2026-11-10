defmodule PlaywrightEx.Runtime.Zones do
  @upstream "packages/utils/zones.ts"
  @moduledoc """
  Port of `#{@upstream}` (AsyncLocalStorage). Zones become process-dictionary entries:
  an async function runs (and awaits) in a single process, so per-process storage has the
  same scoping as an async context. `PlaywrightEx.Runtime.Promise.async/2` and listener processes copy the zone into the new
  process (an async function called without `await` inherits its caller's context).
  """
  @key :playwright_ex_zone

  # currentZone().with(type, data).run(func)
  def with(type, data, func), do: run(Map.put(current_zone(), type, data), func)

  # currentZone().without(type)
  def without(type), do: Map.delete(current_zone(), type)

  # savedZone.run(func)
  def run(zone, func) do
    previous = current_zone()
    Process.put(@key, zone)

    try do
      func.()
    after
      Process.put(@key, previous)
    end
  end

  # currentZone().data(type)
  def data(type), do: Map.get(current_zone(), type)

  # Zone data objects are mutable in JS (e.g. `apiZone.reported = true`).
  def update(type, fun) do
    zone = current_zone()
    if Map.has_key?(zone, type), do: Process.put(@key, Map.update!(zone, type, fun))
    data(type)
  end

  def current_zone, do: Process.get(@key, %{})
  def restore(zone), do: Process.put(@key, zone)
end
