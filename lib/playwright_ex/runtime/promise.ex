defmodule PlaywrightEx.Runtime.Promise do
  @moduledoc """
  Runtime support (not ported from upstream): JS promises on the baton.

  * Heap promises (`new Promise(executor)`, `ManualPromise`): state in the heap, executors
    and reactions run synchronously by the holder that creates/settles them.
  * `await/1` releases the baton while pending (`EventLoop.suspend/0`); the settling holder
    schedules the awaiting process, which resumes before the next macrotask.
  * `async/1` mirrors calling a JS `async` function without awaiting it: the function runs
    in a fresh process holding the baton until its first `await`, then the caller
    continues (`EventLoop.spawn_handoff/1`). Outside the baton (test code) it is Task-backed
    and returns once the task reaches its first suspension point.

  * Rows: a pending promise has `:state`, `:reactions` and `:awaiters`, a settled one only
    `:state`, freed by `PlaywrightEx.Runtime.GC` once nothing can reach the promise. Awaiters
    get the result in their wake-up message.

  Like JS, ported code names no loop: `new/0,1`, `race/1`, `all/1`, `rejected/1` and
  `async/1` use the loop of the baton holder (`EventLoop.current!/0`).
  """
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap

  require Logger

  defstruct [:guid, :loop, :heap, :task]

  # new Promise((resolve, reject) => ...)
  def new(executor \\ fn _resolve, _reject -> nil end) do
    promise = Heap.new_object(__MODULE__)
    Heap.put(promise, :state, :pending)
    Heap.put(promise, :reactions, [])
    Heap.put(promise, :awaiters, [])

    try do
      executor.(fn value -> resolve(promise, value) end, fn error -> reject(promise, error) end)
    rescue
      e -> reject(promise, e)
    end

    promise
  end

  def resolve(promise, value), do: settle(promise, {:ok, value})
  def reject(promise, error), do: settle(promise, {:error, error})

  # A settled promise keeps only its `:state` row; awaiters get the result in a message.
  defp settle(%__MODULE__{loop: loop, guid: guid} = promise, result) do
    EventLoop.with_baton(loop, fn ->
      if Heap.get(promise, :state) == :pending do
        Heap.put(promise, :state, result)
        reactions = Heap.get(promise, :reactions)
        awaiters = Heap.get(promise, :awaiters)
        Heap.delete(promise, :reactions)
        Heap.delete(promise, :awaiters)

        Enum.each(awaiters, fn pid ->
          send(pid, {:pw_settled, guid, result})
          EventLoop.ready(pid)
        end)

        Enum.each(reactions, fn reaction -> run_reaction(reaction, result) end)
      end

      nil
    end)
  end

  defp run_reaction(reaction, result) do
    reaction.(result)
  rescue
    e -> Logger.error("Uncaught in promise reaction: " <> Exception.format(:error, e, __STACKTRACE__))
  end

  @doc false
  def on_settled(%__MODULE__{loop: loop} = promise, reaction) do
    EventLoop.with_baton(loop, fn ->
      case Heap.get(promise, :state) do
        :pending -> Heap.update(promise, :reactions, &(&1 ++ [reaction]))
        nil -> raise collected(promise)
        result -> run_reaction(reaction, result)
      end
    end)
  end

  # promise.then(onFulfilled)
  def then_(%__MODULE__{loop: loop} = promise, on_fulfilled) do
    EventLoop.with_baton(loop, fn ->
      new(fn resolve, reject ->
        on_settled(promise, fn
          {:ok, value} ->
            try do
              resolve.(on_fulfilled.(value))
            rescue
              e -> reject.(e)
            end

          {:error, error} ->
            reject.(error)
        end)
      end)
    end)
  end

  # promise.catch(onRejected)
  def catch_(%__MODULE__{loop: loop} = promise, on_rejected) do
    EventLoop.with_baton(loop, fn ->
      new(fn resolve, _reject ->
        on_settled(promise, fn
          {:ok, value} -> resolve.(value)
          {:error, error} -> resolve.(on_rejected.(error))
        end)
      end)
    end)
  end

  # Promise.race([...])
  def race(promises) do
    new(fn resolve, reject ->
      for promise <- promises do
        on_settled(promise, fn
          {:ok, value} -> resolve.(value)
          {:error, error} -> reject.(error)
        end)
      end
    end)
  end

  # Promise.all([...])
  def all([]), do: new(fn resolve, _ -> resolve.([]) end)

  def all(promises) do
    new(fn resolve, reject ->
      acc = Heap.new_object(__MODULE__)
      Heap.put(acc, :values, %{})
      count = length(promises)

      for {promise, index} <- Enum.with_index(promises) do
        on_settled(promise, fn
          {:ok, value} ->
            values = Heap.update(acc, :values, &Map.put(&1, index, value))
            if map_size(values) == count, do: resolve.(Enum.map(0..(count - 1), &values[&1]))

          {:error, error} ->
            reject.(error)
        end)
      end
    end)
  end

  # Promise.reject(e)
  def rejected(error), do: new(fn _resolve, reject -> reject.(error) end)

  # await promise
  def await(%__MODULE__{task: %Task{} = task}) do
    case EventLoop.blocking(fn -> Task.await(task, :infinity) end) do
      {:ok, value} -> value
      {:error, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  def await(%__MODULE__{loop: loop, guid: guid} = promise) do
    result =
      case Heap.get(promise, :state) do
        :pending ->
          EventLoop.with_baton(loop, fn ->
            case Heap.get(promise, :state) do
              :pending ->
                Heap.update(promise, :awaiters, &(&1 ++ [self()]))
                EventLoop.suspend()

                receive do
                  {:pw_settled, ^guid, result} -> result
                end

              settled ->
                settled
            end
          end)

        nil ->
          raise collected(promise)

        # settled promises are immutable: no baton needed to read them
        settled ->
          settled
      end

    case result do
      {:ok, value} -> value
      {:error, %{__exception__: true} = error} -> raise error
      {:error, other} -> raise "Promise rejected with #{inspect(other)}"
    end
  end

  # Only an unreachable promise is collected; a handle older than the last 1000 returned to one
  # process is (see `PlaywrightEx.Runtime.GC`).
  defp collected(promise), do: %RuntimeError{message: "Promise #{inspect(promise.guid)} was garbage collected"}

  @doc """
  Call an async function without awaiting it. Under the baton: a heap promise (race-able,
  awaitable by any process); outside it (test code): Task-backed.
  """
  def async(fun) when is_function(fun, 0) do
    if EventLoop.held?(), do: heap_async(fun), else: task_async(fun)
  end

  defp heap_async(fun) do
    promise = new()

    EventLoop.spawn_handoff(fn ->
      try do
        resolve(promise, fun.())
      catch
        kind, reason -> reject(promise, Exception.normalize(kind, reason, __STACKTRACE__))
      end
    end)

    promise
  end

  defp task_async(fun) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Process.put(:pw_async_parent, {parent, ref})

        result =
          try do
            {:ok, fun.()}
          catch
            kind, reason -> {:error, kind, reason, __STACKTRACE__}
          end

        EventLoop.notify_async_parent()
        result
      end)

    receive do
      {^ref, :suspended} -> :ok
    end

    %__MODULE__{task: task}
  end
end
