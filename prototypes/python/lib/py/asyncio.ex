defmodule Asyncio.Future do
  @moduledoc """
  asyncio.Future (runtime shim, NOT ported). State lives in the heap
  (`insert_new` makes set_result/set_exception first-wins and atomic); any
  process may await it. Awaiters register in a bag table and get a message.
  """
  use Py

  def new, do: Py.new(__MODULE__)

  def done(%{__id__: id}), do: :ets.member(Py.heap(), {id, :__state__})
  def cancelled(f), do: Py.get(f, :__state__) == :cancelled

  def set_result(f, value), do: settle(f, {:ok, value})
  def set_exception(f, exception), do: settle(f, {:error, exception})
  def cancel(f), do: settle(f, :cancelled)

  defp settle(%{__id__: id} = f, state) do
    if :ets.insert_new(Py.heap(), {{id, :__state__}, state}) do
      for {_, pid} <- :ets.take(:py_future_waiters, id), do: send(pid, {:py_future_done, id})
      true
    else
      raise "InvalidStateError: #{inspect(f)} already done"
    end
  end

  @doc "`fut.result()` on a done future."
  def result(f) do
    case Py.get(f, :__state__) do
      {:ok, v} -> v
      {:error, e} -> raise e
      :cancelled -> raise Asyncio.CancelledError
      nil -> raise "InvalidStateError: result is not set"
    end
  end

  def exception(f) do
    case Py.get(f, :__state__) do
      {:error, e} -> e
      _ -> nil
    end
  end

  @doc "`await fut`"
  def await(%{__id__: id} = f) do
    :ets.insert(:py_future_waiters, {id, self()})

    unless done(f) do
      receive do
        {:py_future_done, ^id} -> :ok
      end
    end

    :ets.delete_object(:py_future_waiters, {id, self()})
    result(f)
  end
end

defmodule Asyncio.CancelledError do
  defexception message: "Task was cancelled"
end

defmodule Asyncio.Task do
  @moduledoc "asyncio.Task: a process whose outcome settles a Future."
  defstruct [:__id__, :pid]
  defdelegate done(t), to: Asyncio.Future
  defdelegate result(t), to: Asyncio.Future
  defdelegate await(t), to: Asyncio.Future

  def cancel(%__MODULE__{pid: pid} = t) do
    Process.exit(pid, :kill)
    unless done(t), do: Asyncio.Future.cancel(t)
  end
end

defmodule Asyncio do
  @moduledoc "asyncio module functions (runtime shim, NOT ported)."
  alias Asyncio.Future

  @doc "`asyncio.create_task(coro())` -> spawns an unlinked process."
  def create_task(fun) do
    %{__id__: id} = future = Future.new()

    pid =
      spawn(fn ->
        try do
          Future.set_result(future, fun.())
        rescue
          e -> Future.set_exception(future, e)
        end
      end)

    %Asyncio.Task{__id__: id, pid: pid}
  end

  def sleep(seconds), do: Process.sleep(round(seconds * 1000))

  @doc "`asyncio.wait(futures, return_when=FIRST_COMPLETED)` -> {done, pending}"
  def wait_first_completed(futures) do
    ids = Enum.map(futures, & &1.__id__)
    for id <- ids, do: :ets.insert(:py_future_waiters, {id, self()})

    unless Enum.any?(futures, &Future.done/1), do: receive_any(ids)

    for id <- ids, do: :ets.delete_object(:py_future_waiters, {id, self()})
    Enum.split_with(futures, &Future.done/1)
  end

  defp receive_any(ids) do
    receive do
      {:py_future_done, id} -> if id in ids, do: :ok, else: receive_any(ids)
    end
  end
end
