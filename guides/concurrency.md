# Concurrency

JS runs Playwright on one thread. This port runs it in Elixir processes, and that changes a
few things you can rely on. Snippets alias `Playwright.{Page, BrowserContext, Promise, ...}`.

## Connections and your processes

Each driver connection is one process. It dispatches the driver's messages one at a time, in
order, and holds the state of every page, context and handle in an ETS table. Your calls run in
your own processes and read that state without a round trip, so calls from many processes
(tests, LiveViews, tasks) overlap freely, as concurrent `async` calls do in JS.

## Listeners run in processes

A listener added with `on/3` or `once/3` runs in a process of its own for each event; a route
handler runs in a process per request. The connection
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

## Waiting in listeners

The connection waits for each listener until it returns or awaits. Playwright's own waits
count as awaits; a wait on anything else (`receive`, `Process.sleep/1`, an HTTP request) is
synchronous code to the connection, and stalls every page on it, as blocking the event loop does
in JS. Where JS awaits such a wait (a promise the test resolves later), call
`Playwright.Promise.yield/0` first: the listener's synchronous section ends there, as at a JS
`await`, and the connection dispatches on while the listener waits:

```elixir
test_pid = self()

Page.route(page, "**/api/data", fn route ->
  # JS: `await released; await route.continue()`.
  send(test_pid, {:held, self()})
  Promise.yield()

  receive do
    :release -> Route.continue!(route)
  end
end)

# ... the page requests /api/data ...
assert_receive {:held, held}
Expect.to_be_visible!(Page.get_by_text(page, "Loading"))
send(held, :release)
```

A listener that hasn't reached a Playwright await within 100 ms is released, so its remaining
synchronous code may run after later events; a warning names `yield/0`. Call `yield/0` before
waiting outside Playwright, and the connection doesn't wait those 100 ms. Slow work that JS
would not await (logging to a service, say) goes to another process with `send/2` or
`Task.start/1`.

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
`Playwright.Promise.free/1` drops a wait you no longer need.

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

  `Promise.all([a, b])` is a `Promise.async/1` for each, then a `Promise.await!/1` for each.

- `Task.async/1` when the call only completes after a later action of yours, such as a `click`
  that opens a dialog you then handle: awaiting it in line would deadlock, and the order of the
  sends doesn't matter, as you wait for the event the call causes.

  ```elixir
  dialog = Page.wait_for_event(page, :dialog)
  click = Task.async(fn -> Locator.click!(Page.get_by_role(page, :button)) end)
  Dialog.accept!(Promise.await!(dialog))
  Task.await(click)
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
- Code after a call runs in your process when the reply arrives, so the connection may already
  have dispatched the next events; JS runs it before the next message.
