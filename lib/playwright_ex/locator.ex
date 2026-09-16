defmodule PlaywrightEx.Locator do
  @moduledoc """
  Client-composed operations on lazy selector queries.

  Queries are rooted at a frame and use Playwright selectors, including frame
  traversal. Target resolution and strictness belong to the browser driver.
  """

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Frame

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [type: :string, required: true],
      expression: [type: :string, required: true],
      is_function: [type: :boolean, default: false],
      arg: [type: :any, default: nil]
    )

  @doc """
  Waits for one attached element, evaluates on it, and disposes its handle.

  Follows Playwright JS `Locator.evaluate`: the timeout covers locating the
  element, not executing JavaScript; disposal also runs after an evaluation failure. Function
  expressions receive the element and optional argument. Disposal has no timeout;
  non-target-closed disposal errors take precedence over the evaluation result.
  No element handle escapes.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @doc group: :composed
  @type evaluate_opt :: unquote(NimbleOptions.option_typespec(schema))
  @schema schema
  @spec evaluate(PlaywrightEx.guid(), [evaluate_opt()]) :: {:ok, any()} | {:error, any()}
  def evaluate(frame_id, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @schema)
    connection = Keyword.fetch!(opts, :connection)
    timeout = Keyword.fetch!(opts, :timeout)

    with {:ok, %{guid: element_id}} <-
           Frame.wait_for_selector(frame_id,
             connection: connection,
             selector: Keyword.fetch!(opts, :selector),
             state: "attached",
             strict: true,
             timeout: timeout
           ) do
      outcome =
        try do
          opts = opts |> Keyword.delete(:selector) |> Keyword.put(:timeout, :infinity)
          {:returned, ElementHandle.evaluate(element_id, opts)}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end

      # Like JS finally, a disposal failure takes precedence over evaluation.
      with {:ok, _} <- ElementHandle.dispose(element_id, connection: connection, timeout: :infinity) do
        evaluation_result(outcome)
      end
    end
  end

  defp evaluation_result({:returned, result}), do: result
  defp evaluation_result({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)
end
