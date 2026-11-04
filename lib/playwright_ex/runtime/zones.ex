defmodule PlaywrightEx.Runtime.Zones do
  @upstream "packages/utils/zones.ts"
  @moduledoc """
  Port of `#{@upstream}` (AsyncLocalStorage). Zones become process-dictionary entries:
  an async function runs (and awaits) in a single process, so per-process storage has the
  same scoping as an async context. `Baton.spawn_handoff/1` copies the zone into the new
  process (an async function called without `await` inherits its caller's context).
  """
  @key :playwright_ex_zone

  # currentZone().data(type)
  def data(type), do: Map.get(Process.get(@key, %{}), type)

  # currentZone().with(type, data).run(func)
  def with(type, data, func) do
    previous = Process.get(@key, %{})
    Process.put(@key, Map.put(previous, type, data))

    try do
      func.()
    after
      Process.put(@key, previous)
    end
  end

  # emptyZone.run(func)
  def empty(func) do
    previous = Process.get(@key, %{})
    Process.put(@key, %{})

    try do
      func.()
    after
      Process.put(@key, previous)
    end
  end

  # currentZone().without(type)
  def without(type), do: Map.delete(Process.get(@key, %{}), type)

  # savedZone.run(func)
  def run(zone, func) do
    previous = Process.get(@key, %{})
    Process.put(@key, zone)

    try do
      func.()
    after
      Process.put(@key, previous)
    end
  end

  # Zone data objects are mutable in JS (e.g. `apiZone.reported = true`).
  def update(type, fun) do
    zone = Process.get(@key, %{})
    if Map.has_key?(zone, type), do: Process.put(@key, Map.update!(zone, type, fun))
    data(type)
  end

  def current, do: Process.get(@key, %{})
  def restore(zone), do: Process.put(@key, zone)
end
