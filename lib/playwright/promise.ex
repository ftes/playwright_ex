defmodule Playwright.Promise do
  @moduledoc """
  A pending result, as returned by the waits that JS starts without `await`
  (`Playwright.Page.wait_for_event/3`, `wait_for_request/3`, `wait_for_navigation/2`, ...):

      popup = Playwright.Page.wait_for_event(page, :popup)
      Playwright.Page.click!(page, "a[target=_blank]")
      {:ok, popup} = Playwright.Promise.await(popup)

  The wait is set up before the function returns, so events of the actions that follow are
  seen.

  A promise is owned by the process that started it. Unlike a plain Elixir `Task`, any process
  can await it, any number of times, and gets the same result, which is kept while the owner
  lives. Once the owner has exited, awaiting raises `Playwright.TargetClosedError`. A promise
  started inside an event listener is owned by the object it waits on (`page` in
  `wait_for_event(page, ...)`) instead, since the listener's process may exit first; it lives
  until that object is freed after close.
  `free/1` drops a promise you no longer need before its owner exits.

  The same waits have a callback form, as in the other official clients
  (`Playwright.Page.expect_popup(page, fn -> ... end)`).

  `async/1` starts any calls this way, as JS's `const p = locator.evaluate(...)` (see the
  [Concurrency](concurrency.md) guide). `yield/0` is the `await` of a wait that isn't Playwright's.
  """

  @typedoc "A promise handle."
  @type t :: %Playwright.Runtime.Promise{}

  @doc """
  Calls `fun` without waiting for it, as JS starts an async call without `await`
  (`const p = locator.evaluate(...); ...; await p`). `fun` runs in a process of its own, and
  `async/1` returns once `fun` returned or first waits on Playwright (for a call's reply, an
  event), so the calls it made by then are sent before your next action, in order:

      # The click comes after the evaluate is in place.
      clicked = Promise.async(fn -> Page.evaluate!(page, "() => new Promise(r => onclick = () => r(1))") end)
      Page.click!(page, "body")
      1 = Promise.await!(clicked)

  A `Task` gives no such order: its first call may be sent after the next action. Work before the
  first Playwright call delays the return; a wait there (a `Process.sleep/1`) by about 30 ms at
  most, as it is taken for an await (see `yield/0`).

  The promise is owned by the calling process, as the waits' are (in an event listener, by the
  process that added the listener): any process can await it, any number of times, until that
  process exits. An error of `fun` is its result, raised by
  `await!/1` (`await/1` returns a `t:Playwright.error/0`); one nobody awaits is dropped. The
  process carries the caller's `$callers`, as a `Task`'s does, so `Playwright.Test` (soft
  matchers, steps), the Ecto sandbox and Mox find the test.
  """
  @spec async((-> term())) :: t()
  def async(fun) when is_function(fun, 0), do: Playwright.Runtime.Promise.async(fun, shared: true)

  @doc """
  Waits for the promise: `{:ok, value}`, or `{:error, exception}` if it is rejected with a
  `t:Playwright.error/0`. Other exceptions (bugs) are raised.
  """
  @spec await(t()) :: {:ok, term()} | {:error, Playwright.error()}
  def await(%Playwright.Runtime.Promise{} = promise) do
    {:ok, Playwright.Runtime.Promise.await(promise)}
  rescue
    e -> if Playwright.Runtime.Facade.error?(e), do: {:error, e}, else: reraise(e, __STACKTRACE__)
  end

  @doc "Like `await/1`, but returns the value and raises if the promise is rejected."
  @spec await!(t()) :: term()
  def await!(%Playwright.Runtime.Promise{} = promise), do: Playwright.Runtime.Promise.await(promise)

  @doc """
  Elixir only: the port of an `await` on something that isn't Playwright's (a promise the test
  resolves, a timer, `fetch`). An event listener or route handler runs synchronously, holding up
  its connection's dispatch, until it returns or first awaits; Playwright's own waits do that by
  themselves, a `receive` or `Process.sleep/1` does not. Call `yield/0` before such a wait, and
  the connection dispatches on while it lasts (in an `async/1` function, its caller continues):

      # JS: `await page.route('**/api', async route => { await released; await route.continue(); })`
      Page.route!(page, "**/api", fn route ->
        send(test_pid, {:held, self()})
        Playwright.Promise.yield()

        receive do
          :release -> Route.continue!(route)
        end
      end)

  Elsewhere, and after the first await, it does nothing. Without it, a wait that lasts about
  30 ms is taken for an await, with a warning. See the [Concurrency](concurrency.md) guide.
  """
  @spec yield() :: :ok
  def yield do
    # A finished test kills a process still waiting (`Runtime.Callers.detached/2`).
    if Process.get(:pw_inv), do: Playwright.Runtime.Callers.detached(self(), Process.get(:"$callers"))
    Playwright.Runtime.Invocation.yield()
  end

  @doc """
  Elixir only: drops a promise nobody will await, such as a wait started before checking state
  that turned out to be ready (see the [Concurrency](concurrency.md) guide). Its result is no longer kept, no
  late message reaches the caller; don't await it afterwards. Without `free/1` the result is
  kept until the owner exits.
  """
  @spec free(t()) :: :ok
  def free(%Playwright.Runtime.Promise{} = promise), do: Playwright.Runtime.Promise.free(promise)
end
