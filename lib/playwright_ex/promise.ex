defmodule PlaywrightEx.Promise do
  @moduledoc """
  A pending result, as returned by the waits that JS starts without `await`
  (`PlaywrightEx.Page.wait_for_event/3`, `wait_for_request/3`, `wait_for_navigation/2`, ...):

      popup = PlaywrightEx.Page.wait_for_event(page, :popup)
      PlaywrightEx.Page.click!(page, "a[target=_blank]")
      {:ok, popup} = PlaywrightEx.Promise.await(popup)

  The wait is set up before the function returns, so events of the actions that follow are
  seen. Any process can await a promise, any number of times. A promise that is never awaited
  ends as in JS: when its wait settles or times out.

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
end
