# Concurrency

JS runs Playwright on one thread. This port runs it in Elixir processes, and that changes a
few things you can rely on. Snippets alias `Playwright.{Page, BrowserContext, Promise, ...}`.

## Plain Elixir first

`Playwright.Promise` keeps the client port mechanical. In your code, prefer plain Elixir, and use
it only where it is strictly needed:

1. a wait must start before the action that triggers it: an `expect_*!` function, or a
   `wait_for_*` (`wait_for_event/3`, `wait_for_response/3`, `wait_for_navigation/2`) and
   `Promise.await!/1` ([Events and waiting](events-and-waiting.md));
2. a call must be sent before your next action, though its result comes later:
   `Promise.async/1` ([Calls you await later](#calls-you-await-later));
3. several such waits race: `Promise.race/1` (or `any/1`) of waits started before the action.

When several processes need one result, a promise is the simplest option
([Promises from any process](#promises-from-any-process)), though one process can await and `send`.

Otherwise, a JS `Promise.all` of independent reads or assertions only saves time, and their order
doesn't matter: make the calls one after another. Reads can run in `Task`s for real concurrency;
`Task.await/2` and `Task.await_many/2` time out after 5 s by default, so pass `:infinity`, as
Playwright calls time out on their own.

```elixir
# JS: await Promise.all([expect(a).toHaveText('1'), expect(b).toHaveText('2')])
Expect.to_have_text!(a, "1")
Expect.to_have_text!(b, "2")

# JS: const [x, y] = await Promise.all([a.textContent(), b.textContent()])
[x, y] =
  [fn -> Locator.text_content!(a) end, fn -> Locator.text_content!(b) end]
  |> Enum.map(&Task.async/1)
  |> Task.await_many(:infinity)
```

A listener reports with `send/2` (see below), and a call the API docs say doesn't wait
(`Page.close(page, run_before_unload: true)`) is a plain call.

## Connections and your processes

Each driver connection is one process. It dispatches the driver's messages one at a time, in
order, and holds the state of every page, context and handle in an ETS table. Your calls run in
your own processes and read that state without a round trip, so calls from many processes
(tests, LiveViews, tasks) overlap freely, as concurrent `async` calls do in JS.

## Listeners run in processes

A listener added with `on/3` or `once/3` runs in a process of its own, one per subscription,
taking its events one at a time; a route handler runs in a process per request. The connection
waits until the listener or handler returns or awaits a Playwright call before it dispatches the
next message, as JS runs a listener until its first `await`. That keeps JS's guarantees:

- an event is handled before the reply of the call that caused it, so after
  `Page.evaluate!(page, "console.log('hi')")` returns, your `:console` listener has run;
- listeners of one event run in the order they were added;
- a listener can call Playwright (accept a dialog, fulfill a route) without deadlocking.

The usual pattern is a listener that only sends a message to the process that owns the work:

```elixir
owner = self()
Page.on(page, :console, fn msg -> send(owner, {:console, ConsoleMessage.text(msg)}) end)
```

## No blocking work in listeners

Since the connection waits for each listener, one that blocks on something other than
Playwright (`Process.sleep/1`, `receive`, an HTTP request, a `GenServer.call` to a busy server)
stalls every page on that connection, as blocking the event loop does in JS. Hand slow work to
another process with `send/2` or `Task.start/1`. When the connection has waited 5 s for one
listener or handler, it logs a warning with the listener and where it waits.

A handler that waits for the test (JS awaits a promise the test resolves later) hands the work to
a process that waits instead, and returns:

```elixir
test_pid = self()

Page.route(page, "**/api/data", fn route ->
  # JS: `await released; await route.continue()`.
  spawn(fn ->
    send(test_pid, {:held, self()})

    receive do
      :release -> Route.continue!(route)
    end
  end)
end)

# ... the page requests /api/data ...
assert_receive {:held, held}
Expect.to_be_visible!(Page.get_by_text(page, "Loading"))
send(held, :release)
```

## Subscribe before you check

In JS, nothing runs between two lines without an `await`, so "read state, then wait for the event
that changes it" cannot miss the event. Here the connection keeps dispatching between your two
calls, so the event can land in between, and the wait then hangs. Start the wait first, then read
the state, then await the wait or free it:

```elixir
# JS: context.serviceWorkers()[0] ?? await context.waitForEvent('serviceworker')
promise = BrowserContext.wait_for_event(context, :service_worker)

case BrowserContext.service_workers(context) do
  [worker | _] ->
    Promise.free(promise)
    worker

  [] ->
    Promise.await!(promise)
end
```

The client's own waits (`wait_for_url`, `wait_for_load_state`, `wait_for_navigation`, the
matchers) already do this. Only code that checks state itself and then waits needs it.

## Promises from any process

`wait_for_*` returns a `Playwright.Promise`. Unlike a `Task`, any process can await it, any
number of times, and gets the same result. The result is kept while the process that started the
wait lives; after it has exited, awaiting raises `Playwright.TargetClosedError`.
`Playwright.Promise.free/1` drops a wait you no longer need (one still pending when freed keeps its result, if it settles later, until the process exits).

```elixir
download = Page.wait_for_event(page, :download)
Locator.click!(Page.get_by_text(page, "Export"))
task = Task.async(fn -> Download.path!(Promise.await!(download)) end)
```

## Calls you await later

JS starts a call and awaits it later: `const p = locator.evaluate(...); ...; await p`. Which
Elixir form fits depends on when the call completes:

- `Playwright.Promise.async/1` when the call must be sent before your next action, say an
  `evaluate` that resolves on a click. It returns once the call is sent; a `Task` may send it
  after the click.

  ```elixir
  clicked = Promise.async(fn -> Page.evaluate!(page, "() => new Promise(r => onclick = () => r(true))") end)
  Locator.click!(Page.get_by_role(page, :button))
  true = Promise.await!(clicked)
  ```

  A JS `Promise.all([...])` that starts a wait with its action is case 1 of
  [Plain Elixir first](#plain-elixir-first): start the wait, act, then await it.
  `Promise.all/1`, `Promise.race/1` and `Promise.any/1` of `async/1` calls and waits are the
  literal port, and only combine them:

  ```elixir
  # JS: await Promise.all([page.waitForNavigation(), page.click('a')])
  nav = Page.wait_for_navigation(page)
  Page.click!(page, "a")
  Promise.await!(nav)

  # Literal port:
  Promise.all([Page.wait_for_navigation(page), Promise.async(fn -> Page.click!(page, "a") end)])
  |> Promise.await!()
  ```

  JS's `p.then(f)` is `Promise.async(fn -> f.(Promise.await!(p)) end)`. A `.then` that only
  tags which input of a `race` won needs none: match on the result
  (`%Playwright.Download{}` or the page's error).

- `Task.async/1` when the call only completes after a later action of yours, such as a `click`
  that opens a dialog you then handle: awaiting it in line would deadlock, and the order of the
  sends doesn't matter, as you wait for the event the call causes.

  ```elixir
  dialog = Page.wait_for_event(page, :dialog)
  click = Task.async(fn -> Locator.click!(Page.get_by_role(page, :button)) end)
  Dialog.accept!(Promise.await!(dialog))
  Task.await(click, :infinity)
  ```

## Lifetimes after close

As in JS, a closed page or context stays readable: [`Page.url/1`](`Playwright.Page.url/1`) and
other accessors return the last values. That lasts until every process that created or closed its
context (or browser) has exited; after that, reading it raises `Playwright.TargetClosedError`. A
process that lives for long and closes many contexts keeps a few hundred rows per context until it
exits, so in a long-running service, create each context in a process that ends with the session.

Handles of a lost driver stay readable the same way; `Playwright.Supervisor` has the details.

## Where it differs from JS

- A listener that awaits a Playwright call holds back later events of its own subscription until
  it returns; JS interleaves them. Other listeners and calls carry on.
- A wait rejected by an event (a page closing under `wait_for_event`) settles in the waiting
  process, so it may notice after a later event; JS rejects it synchronously inside the emit.
- Code after a call or a wait runs in your process once it settles, so the connection may already
  have dispatched the next events; JS runs it before the next message. A getter such as
  [`Request.frame/1`](`Playwright.Request.frame/1`) or [`Page.url/1`](`Playwright.Page.url/1`)
  may then already show what they changed: don't assert a state that lasts only until the next
  event (a popup's first request without a frame yet).
