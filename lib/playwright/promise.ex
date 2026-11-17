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
  `all/1`, `race/1` and `any/1` combine a list of promises, as JS's `Promise.all`, `Promise.race`
  and `Promise.any`. Unlike JS's, they compare their inputs when you await them: inputs already
  settled by then go in list order, so a later await may pick another winner. Awaited right away,
  they behave as in JS. They take the promises the API returns (`async/1`, the waits), not a
  local promise (from the runtime's `async`), which can be awaited once, as a `Task`.
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
  first Playwright call delays the return; a wait there (a `Process.sleep/1`) by 100 ms at most,
  as `fun` is then released as if it had awaited (see `yield/0`).

  The promise is owned by the calling process, as the waits' are (in an event listener, by the
  process that added the listener): any process can await it, any number of times, until that
  process exits. An error of `fun` is its result, raised by `await!/1` and returned by `await/1`
  if it is a `t:Playwright.error/0`; one nobody awaits is dropped. The
  process carries the caller's `$callers`, as a `Task`'s does, so `Playwright.Test` (soft
  matchers, steps), the Ecto sandbox and Mox find the test.
  """
  @spec async((-> term())) :: t()
  def async(fun) when is_function(fun, 0), do: Playwright.Runtime.Promise.async(fun, shared: true)

  @doc """
  Waits for the promise: `{:ok, value}`, or `{:error, exception}` if it is rejected with a
  `t:Playwright.error/0`, or with an `any/1`'s `Playwright.AggregateError` of such errors. Other
  exceptions (bugs) are raised.
  """
  @spec await(t()) :: {:ok, term()} | {:error, Playwright.error() | Playwright.AggregateError.t()}
  def await(%Playwright.Runtime.Promise{} = promise) do
    {:ok, Playwright.Runtime.Promise.await(promise)}
  rescue
    e -> if error?(e), do: {:error, e}, else: reraise(e, __STACKTRACE__)
  end

  # `any/1`'s error is one when each of its errors is.
  defp error?(%Playwright.AggregateError{errors: errors}), do: Enum.all?(errors, &error?/1)
  defp error?(e), do: Playwright.Runtime.Facade.error?(e)

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

  Elsewhere, and after the first await, it does nothing. Without it, a listener that hasn't
  reached a Playwright await within 100 ms is released, with a warning, so its remaining
  synchronous code may run after later events. See the [Concurrency](concurrency.md) guide.
  """
  @spec yield() :: :ok
  def yield, do: Playwright.Runtime.Invocation.yield()

  @doc """
  `Promise.all(promises)`: the values in input order, or the first rejection, without waiting
  for the rest. `all([])` resolves to `[]`. The inputs must be promises: a call in the list
  (`Page.click!(...)`) has already run, so start it with `async/1`.

      # JS: const [response] = await Promise.all([page.waitForResponse('**/api'), page.click('button')])
      [response, _] =
        Promise.all([
          Page.wait_for_response(page, "**/api"),
          Promise.async(fn -> Page.click!(page, "button") end)
        ])
        |> Promise.await!()

  The inputs run on whatever the outcome, and stay awaitable. The combined promise holds
  nothing of its own: free its inputs, not it.
  """
  @spec all([t()]) :: t()
  def all(promises) when is_list(promises), do: Playwright.Runtime.Promise.all(promises!(promises, "all"))

  @doc """
  `Promise.race(promises)`: settles as the first input to settle, fulfilled or rejected.
  `race([])` never settles, as in JS. Otherwise as `all/1`.

      # JS: await Promise.race([page.waitForEvent('popup'), page.waitForEvent('download')])
      Promise.race([Page.wait_for_event(page, :popup), Page.wait_for_event(page, :download)])
      |> Promise.await!()
  """
  @spec race([t()]) :: t()
  def race(promises) when is_list(promises), do: Playwright.Runtime.Promise.race(promises!(promises, "race"))

  @doc """
  `Promise.any(promises)`: the first value, ignoring rejections until all inputs have
  rejected; then a `Playwright.AggregateError` with each rejection in input order. `any([])`
  rejects with one at once. `await/1` returns it as `{:error, error}` when each of its errors is a
  `t:Playwright.error/0`, and raises it otherwise. Otherwise as `all/1`.

      # JS: await Promise.any([page.waitForURL('**/home'), page.waitForURL('**/welcome')])
      Promise.any([
        Promise.async(fn -> Page.wait_for_url!(page, "**/home") end),
        Promise.async(fn -> Page.wait_for_url!(page, "**/welcome") end)
      ])
      |> Promise.await!()
  """
  @spec any([t()]) :: t()
  def any(promises) when is_list(promises), do: Playwright.Runtime.Promise.any(promises!(promises, "any"))

  # The API's promises: latches (`async/1`, the waits) and their combinations. A local promise
  # of the runtime can be awaited once, by its creator.
  defp promises!(promises, name) do
    for promise <- promises do
      case promise do
        %Playwright.Runtime.Promise{kind: :local} ->
          raise ArgumentError,
                "Playwright.Promise.#{name}/1 expects promises the API returns; await a local promise directly"

        %Playwright.Runtime.Promise{} ->
          :ok

        other ->
          raise ArgumentError, "Playwright.Promise.#{name}/1 expects promises, got: #{inspect(other)}"
      end
    end

    promises
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
