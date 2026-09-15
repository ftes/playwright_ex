defmodule PlaywrightEx.EventWaiter do
  @moduledoc """
  Captures the first matching protocol event using a linked `Task`.

  Call `arm/3`, trigger the action, then call `await/1`. Registration completes
  before `arm/3` returns. The event timeout starts when arming begins; filtering
  events or awaiting later does not restart it.

  Only the process that armed the listener can await or cancel it. Await once,
  and cancel in an `after` block if the action can raise. Owner exit cleans up
  the task; unexpected task failures propagate to the owner.

  An optional `:predicate` filters raw event maps. Returning `false` or `nil`
  skips an event. Keep predicates quick and nonblocking.

  Events are matched by channel GUID and message `method`. Unrelated events
  are discarded without extending the timeout. Opt-in Page and BrowserContext
  events are enabled before arming returns and released when the task exits.
  Routing stays at the protocol level: console and network messages arrive on
  the BrowserContext channel, with the page identified in their parameters.

  An optional `:transform` runs in the task when the predicate accepts an event,
  without waiting for `await/1`. It can capture metadata or handle a dialog while
  the owner's action is blocked. Its return value becomes the successful result.
  The event timeout covers capture, not the transform; give browser commands
  inside it their own timeout. Unexpected callback failures propagate.
  """

  alias PlaywrightEx.Connection
  alias PlaywrightEx.Timeout

  @enforce_keys [:task, :connection]
  defstruct [:task, :connection]

  @opaque t :: %__MODULE__{task: Task.t(), connection: GenServer.name()}
  @type error :: %{reason: atom(), message: String.t()}
  @type result :: {:ok, term()} | {:error, error()}

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout:
        Keyword.put(
          PlaywrightEx.Channel.timeout_opt(),
          :doc,
          "Time to capture an event in milliseconds. `0` means no waiting; `:infinity` disables the timeout."
        ),
      predicate: [type: {:fun, 1}, doc: "Filter applied to raw event maps. The first truthy result accepts the event."],
      transform: [type: {:fun, 1}, doc: "Maps the accepted raw event to the result, inside the waiting task."],
      subscription: [
        type:
          {:in,
           [:console, :dialog, :dialog_closed, :file_chooser, :request, :response, :request_finished, :request_failed]},
        doc:
          "Opt-in event to enable when it differs from the raw message method, e.g. `:dialog` for a Dialog `:__create__`."
      ]
    )

  @schema schema
  @type opt :: unquote(NimbleOptions.option_typespec(schema))

  @doc """
  Arms a one-shot listener for `event` on `guid`.

  Fails if the channel has already been disposed. The calling process owns the
  task; its exit cleans up even if `await/1` was never called.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @spec arm(PlaywrightEx.guid(), atom(), [opt() | PlaywrightEx.unknown_opt()]) :: {:ok, t()} | {:error, error()}
  def arm(guid, event, opts \\ []) when is_binary(guid) and is_atom(event) do
    opts = PlaywrightEx.Channel.validate_known!(opts, @schema)
    connection = Keyword.fetch!(opts, :connection)

    case GenServer.whereis(connection) do
      nil -> error(:connection_closed, "Playwright connection is not running")
      pid -> start_task(pid, connection, guid, event, opts)
    end
  end

  @doc """
  Consumes the captured event or waits for the original deadline.

  Like `Task.await/2`, this must be called once, by the process that armed the
  listener. Do not await a consumed or canceled handle.
  """
  @spec await(t()) :: result()
  def await(%__MODULE__{task: task}), do: Task.await(task, :infinity)

  @doc false
  @spec connection(t()) :: GenServer.name()
  def connection(%__MODULE__{connection: connection}), do: connection

  @doc """
  Shuts down the task and discards its result from the owner's mailbox.

  Must be called by the process that armed the listener. Safe to call after
  awaiting or more than once. This cancels event capture, not a browser download
  or the triggering action.
  """
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{task: task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp start_task(connection_pid, connection, guid, event, opts) do
    owner = self()
    timeout = Keyword.fetch!(opts, :timeout)

    callbacks = {
      Keyword.get(opts, :predicate, fn _ -> true end),
      Keyword.get(opts, :transform, &Function.identity/1)
    }

    deadline = Timeout.deadline(timeout)

    task =
      Task.async(fn ->
        # A monitor also covers normal owner exit, which a link does not.
        refs = {Process.monitor(owner), Process.monitor(connection_pid)}
        wait_event(guid, event, callbacks, timeout, deadline, refs)
      end)

    pending = %__MODULE__{task: task, connection: connection}

    case Connection.subscribe_event(connection_pid, task.pid, guid, Keyword.get(opts, :subscription, event)) do
      :ok ->
        {:ok, pending}

      {:error, _} = error ->
        cancel(pending)
        error
    end
  end

  defp wait_event(guid, event, callbacks, timeout, deadline, refs) do
    case Timeout.remaining(deadline) do
      0 -> timeout_error(timeout)
      remaining -> receive_event(guid, event, callbacks, timeout, deadline, refs, remaining)
    end
  end

  defp receive_event(guid, event, callbacks, timeout, deadline, {owner_ref, connection_ref} = refs, remaining) do
    {predicate, transform} = callbacks

    receive do
      {:playwright_msg, %{guid: ^guid, method: ^event} = message} ->
        cond do
          Timeout.remaining(deadline) == 0 -> timeout_error(timeout)
          predicate.(message) -> {:ok, transform.(message)}
          true -> wait_event(guid, event, callbacks, timeout, deadline, refs)
        end

      {:playwright_msg, %{guid: ^guid, method: method}} when method in [:close, :crash, :__dispose__] ->
        error(method, "Playwright channel #{inspect(guid)} emitted #{method} before #{event}")

      {:playwright_msg, %{guid: ^guid}} ->
        wait_event(guid, event, callbacks, timeout, deadline, refs)

      {:DOWN, ^connection_ref, :process, _, _} ->
        error(:connection_closed, "Playwright connection closed")

      {:DOWN, ^owner_ref, :process, _, _} ->
        exit(:normal)
    after
      remaining -> timeout_error(timeout)
    end
  end

  defp timeout_error(timeout), do: error(:timeout, "Timeout #{timeout}ms exceeded while waiting for an event")
  defp error(reason, message), do: {:error, %{reason: reason, message: message}}
end
