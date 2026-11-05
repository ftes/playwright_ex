defmodule PlaywrightEx.Promise do
  @moduledoc """
  A pending result, as returned by the waits that JS starts without `await`
  (`PlaywrightEx.Page.wait_for_event/3`, `wait_for_request/3`, `wait_for_navigation/2`, ...):

      popup = PlaywrightEx.Page.wait_for_event(page, :popup)
      PlaywrightEx.Page.click!(page, "a[target=_blank]")
      {:ok, popup} = PlaywrightEx.Promise.await(popup)

  The wait is set up before the function returns, so events of the actions that follow are
  seen. Any process can await a promise, any number of times, while the process that started it
  lives: its result is kept until then (awaiting after that process exited raises).

  The same waits have a callback form, as in the other official clients
  (`PlaywrightEx.Page.expect_popup(page, fn -> ... end)`).
  """

  @typedoc "A promise handle."
  @type t :: %PlaywrightEx.Runtime.Promise{}

  @doc "Waits for the promise: `{:ok, value}`, or `{:error, exception}` if it is rejected."
  @spec await(t()) :: {:ok, term()} | {:error, Exception.t()}
  def await(%PlaywrightEx.Runtime.Promise{} = promise) do
    {:ok, PlaywrightEx.Runtime.Promise.await(promise)}
  rescue
    e -> {:error, e}
  end

  @doc "Like `await/1`, but returns the value and raises if the promise is rejected."
  @spec await!(t()) :: term()
  def await!(%PlaywrightEx.Runtime.Promise{} = promise), do: PlaywrightEx.Runtime.Promise.await(promise)

  @doc """
  Elixir only: drops a promise nobody will await, such as a wait started before checking state
  that turned out to be ready (see the migration guide, "Subscribe before you check"). Its
  result is no longer kept, and no late message reaches the caller.
  """
  @spec free(t()) :: :ok
  def free(%PlaywrightEx.Runtime.Promise{} = promise), do: PlaywrightEx.Runtime.Promise.free(promise)
end
