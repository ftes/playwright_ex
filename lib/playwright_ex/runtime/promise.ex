defmodule PlaywrightEx.Runtime.Promise do
  @moduledoc """
  Runtime support (not ported from upstream): JS promises on the baton.

  * Heap promises (`new Promise(executor)`, `ManualPromise`): state in the heap, executors
    and reactions run synchronously by the holder that creates/settles them.
  * `await/1` releases the baton while pending (`Baton.suspend/0`); the settling holder
    schedules the awaiting process, which resumes before the next macrotask.
  * `async/2` mirrors calling a JS `async` function without awaiting it: the function runs
    in a fresh process holding the baton until its first `await`, then the caller
    continues (`Baton.spawn_handoff/1`).
  * `async/1` is the same for callers that hold no baton handle (test code): Task-backed,
    returns once the task reaches its first suspension point.
  """
  alias PlaywrightEx.Runtime.Baton
  alias PlaywrightEx.Runtime.Heap

  defstruct [:guid, :baton, :task]

  # new Promise((resolve, reject) => ...)
  def new(%Baton{} = baton, executor \\ fn _resolve, _reject -> nil end) do
    Baton.with_baton(baton, fn ->
      promise = Heap.new_object(baton, __MODULE__)
      Heap.put(promise, :state, :pending)
      Heap.put(promise, :reactions, [])
      Heap.put(promise, :awaiters, [])

      try do
        executor.(fn value -> resolve(promise, value) end, fn error -> reject(promise, error) end)
      rescue
        e -> reject(promise, e)
      end

      promise
    end)
  end

  def resolve(promise, value), do: settle(promise, {:ok, value})
  def reject(promise, error), do: settle(promise, {:error, error})

  defp settle(%__MODULE__{baton: baton} = promise, result) do
    Baton.with_baton(baton, fn ->
      if Heap.get(promise, :state) == :pending do
        Heap.put(promise, :state, result)
        reactions = Heap.get(promise, :reactions)
        awaiters = Heap.get(promise, :awaiters)
        Heap.put(promise, :reactions, [])
        Heap.put(promise, :awaiters, [])
        Enum.each(awaiters, &Baton.ready/1)
        Enum.each(reactions, fn reaction -> run_reaction(reaction, result) end)
      end

      nil
    end)
  end

  defp run_reaction(reaction, result) do
    reaction.(result)
  rescue
    e ->
      require(Logger) && Logger.error("Uncaught in promise reaction: " <> Exception.format(:error, e, __STACKTRACE__))
  end

  @doc false
  def on_settled(%__MODULE__{baton: baton} = promise, reaction) do
    Baton.with_baton(baton, fn ->
      case Heap.get(promise, :state) do
        :pending -> Heap.update(promise, :reactions, &(&1 ++ [reaction]))
        result -> run_reaction(reaction, result)
      end
    end)
  end

  # promise.then(onFulfilled)
  def then_(%__MODULE__{baton: baton} = promise, on_fulfilled) do
    new(baton, fn resolve, reject ->
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
  end

  # promise.catch(onRejected)
  def catch_(%__MODULE__{baton: baton} = promise, on_rejected) do
    new(baton, fn resolve, _reject ->
      on_settled(promise, fn
        {:ok, value} -> resolve.(value)
        {:error, error} -> resolve.(on_rejected.(error))
      end)
    end)
  end

  # Promise.race([...])
  def race(%Baton{} = baton, promises) do
    new(baton, fn resolve, reject ->
      for promise <- promises do
        on_settled(promise, fn
          {:ok, value} -> resolve.(value)
          {:error, error} -> reject.(error)
        end)
      end
    end)
  end

  # Promise.all([...])
  def all(%Baton{} = baton, []), do: new(baton, fn resolve, _ -> resolve.([]) end)

  def all(%Baton{} = baton, promises) do
    new(baton, fn resolve, reject ->
      acc = Heap.new_object(baton, __MODULE__)
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
  def rejected(%Baton{} = baton, error), do: new(baton, fn _resolve, reject -> reject.(error) end)

  # await promise
  def await(%__MODULE__{task: %Task{} = task}) do
    case Baton.blocking(fn -> Task.await(task, :infinity) end) do
      {:ok, value} -> value
      {:error, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  def await(%__MODULE__{baton: baton} = promise) do
    result =
      case Heap.get(promise, :state) do
        :pending ->
          Baton.with_baton(baton, fn ->
            if Heap.get(promise, :state) == :pending do
              Heap.update(promise, :awaiters, &(&1 ++ [self()]))
              Baton.suspend()
            end

            Heap.get(promise, :state)
          end)

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

  @doc "Call an async function without awaiting it (heap promise: race-able, awaitable by any process)."
  def async(%Baton{} = baton, fun) when is_function(fun, 0) do
    Baton.with_baton(baton, fn ->
      promise = new(baton)

      Baton.spawn_handoff(fn ->
        try do
          resolve(promise, fun.())
        catch
          kind, reason -> reject(promise, Exception.normalize(kind, reason, __STACKTRACE__))
        end
      end)

      promise
    end)
  end

  @doc "Call an async function without awaiting it, from code that holds no baton handle (Task-backed)."
  def async(fun) when is_function(fun, 0) do
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

        Baton.notify_async_parent()
        result
      end)

    receive do
      {^ref, :suspended} -> :ok
    end

    %__MODULE__{task: task}
  end
end
