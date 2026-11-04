defmodule PlaywrightJS.Runtime.Promise do
  @moduledoc """
  Runtime support (not ported from upstream): JS promises.

  * Heap promises (`new Promise(executor)`, `ManualPromise`) live on the loop; executors
    and reactions run on the loop; any process may `await/1` them.
  * `async/1,2` mirrors calling a JS `async` function without awaiting it: the function
    runs in a new process and `async` returns once that process reaches its first
    suspension point (first `await`), exactly like JS runs an async function
    synchronously up to its first `await`. This guarantees e.g. that a `waitForEvent`
    listener is registered before the caller continues with `click()`.
  """
  alias PlaywrightJS.Runtime.{Heap, Loop}

  defstruct [:guid, :conn, :task]

  # new Promise((resolve, reject) => ...)
  def new(%Loop{} = loop, executor \\ fn _resolve, _reject -> nil end) do
    Loop.exec(loop, fn ->
      promise = Heap.new_object(loop, __MODULE__)
      Heap.put(promise, :state, :pending)
      Heap.put(promise, :reactions, [])

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

  defp settle(%__MODULE__{conn: loop} = promise, result) do
    Loop.exec(loop, fn ->
      if Heap.get(promise, :state) == :pending do
        Heap.put(promise, :state, result)
        reactions = Heap.get(promise, :reactions)
        Heap.put(promise, :reactions, [])
        Enum.each(reactions, fn reaction -> Loop.run_task(fn -> reaction.(result) end) end)
      end

      nil
    end)
  end

  @doc false
  def on_settled(%__MODULE__{conn: loop} = promise, reaction) do
    Loop.exec(loop, fn ->
      case Heap.get(promise, :state) do
        :pending -> Heap.update(promise, :reactions, &(&1 ++ [reaction]))
        result -> reaction.(result)
      end
    end)
  end

  # promise.then(onFulfilled)
  def then_(%__MODULE__{conn: loop} = promise, on_fulfilled) do
    new(loop, fn resolve, reject ->
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
  def catch_(%__MODULE__{conn: loop} = promise, on_rejected) do
    new(loop, fn resolve, _reject ->
      on_settled(promise, fn
        {:ok, value} -> resolve.(value)
        {:error, error} -> resolve.(on_rejected.(error))
      end)
    end)
  end

  # Promise.race([...])
  def race(%Loop{} = loop, promises) do
    new(loop, fn resolve, reject ->
      for promise <- promises do
        on_settled(promise, fn
          {:ok, value} -> resolve.(value)
          {:error, error} -> reject.(error)
        end)
      end
    end)
  end

  # Promise.reject(e)
  def rejected(%Loop{} = loop, error), do: new(loop, fn _resolve, reject -> reject.(error) end)

  # await promise
  def await(%__MODULE__{task: %Task{} = task}) do
    suspend()

    case Task.await(task, :infinity) do
      {:ok, value} -> value
      {:error, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  def await(%__MODULE__{conn: loop} = promise) do
    if Loop.in_loop?(loop), do: raise("await is not allowed on the event loop (listener/reaction code must not block)")
    suspend()

    case GenServer.call(loop.pid, {:await, promise}, :infinity) do
      {:ok, value} -> value
      {:error, %{__exception__: true} = error} -> raise error
      {:error, other} -> raise "Promise rejected with #{inspect(other)}"
    end
  end

  @doc "Call an async function without awaiting it (owner-awaitable Task-backed promise)."
  def async(fun) when is_function(fun, 0) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Process.put(:playwright_js_async_parent, {parent, ref})

        result =
          try do
            {:ok, fun.()}
          catch
            kind, reason -> {:error, kind, reason, __STACKTRACE__}
          end

        suspend()
        result
      end)

    receive do
      {^ref, :suspended} -> :ok
    end

    %__MODULE__{task: task}
  end

  @doc "Call an async function without awaiting it (heap promise: race-able, awaitable by any process)."
  def async(%Loop{} = loop, fun) when is_function(fun, 0) do
    promise = new(loop)
    in_loop = Loop.in_loop?(loop)
    parent = self()
    ref = make_ref()

    Task.start(fn ->
      unless in_loop, do: Process.put(:playwright_js_async_parent, {parent, ref})

      try do
        value = fun.()
        suspend()
        resolve(promise, value)
      rescue
        e ->
          suspend()
          reject(promise, e)
      end
    end)

    unless in_loop do
      receive do
        {^ref, :suspended} -> :ok
      end
    end

    promise
  end

  defp suspend do
    case Process.delete(:playwright_js_async_parent) do
      {parent, ref} -> send(parent, {ref, :suspended})
      nil -> :ok
    end
  end
end
