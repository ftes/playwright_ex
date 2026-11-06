defmodule PlaywrightEx.Promise do
  @moduledoc """
  A pending result, as returned by the waits that JS starts without `await`
  (`PlaywrightEx.Page.wait_for_event/3`, `wait_for_request/3`, `wait_for_navigation/2`, ...):

      popup = PlaywrightEx.Page.wait_for_event(page, :popup)
      PlaywrightEx.Page.click!(page, "a[target=_blank]")
      {:ok, popup} = PlaywrightEx.Promise.await(popup)

  The wait is set up before the function returns, so events of the actions that follow are
  seen.

  A promise is owned by the process that started it. Unlike a plain Elixir `Task`, any process
  can await it, any number of times, and gets the same result, which is kept while the owner
  lives. Once the owner has exited, awaiting raises `PlaywrightEx.TargetClosedError`. A promise
  started inside an event listener is owned by the object it waits on (`page` in
  `wait_for_event(page, ...)`) instead, since the listener's process may exit first; it lives
  until that object is freed after close.
  `free/1` drops a promise you no longer need before its owner exits.

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
  that turned out to be ready (see the "Concurrency" guide). Its result is no longer kept, no
  late message reaches the caller; don't await it afterwards. Without `free/1` the result is
  kept until the owner exits.
  """
  @spec free(t()) :: :ok
  def free(%PlaywrightEx.Runtime.Promise{} = promise), do: PlaywrightEx.Runtime.Promise.free(promise)
end
