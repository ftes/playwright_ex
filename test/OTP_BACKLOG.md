# OTP runtime backlog (Phase 2)

Phase 2 fixed the route latches, interception patterns, connect-after-initialize, `Promise.all`
strays, remote connection leak, `_actual_headers` and disposed JSHandle rows items. What's left:

- **Waiter rejection**: JS rejects a waiter synchronously inside `emit`; here it settles in the
  waiter's process, so "rejected before the next emit" isn't guaranteed. The mailbox step only
  sends the event; predicate, race, `dispose` and the facade latch's rejection follow in the
  waiter's process. Closing that needs a blocking mailbox step (the connection waits for the
  waiter's ack, its next await or exit) plus a per-process buffer for events of live subscriptions
  the current await doesn't arm (`wait_for_navigation` holds `loadstate` while awaiting
  `navigated`), else dispatch deadlocks. Even then a `.catch` runs in the awaiting process, so
  `browsertype_connect_test`'s "rejected before disconnected" stays adapted.
- **Route handler at teardown** (RO-033, kept): a route callback still pending at close rejects
  with TargetClosedError and the `route` listener drops it unlogged; JS leaves it pending.

Possibly load-flaky, to watch: `locator_query_test.exs:324` (webkit), `conn_test.exs:360`
(120 s timeout once in a loaded full run), `page_screenshot_test.exs:482`,
`page_add_locator_handler_test.exs` "should work" (hover with 2 concurrent pages).
`page_close_test.exs` "should not throw when continuing while page is closing": fixed by caching
the working directory of stack frames (ISSUES.md #7); the driver race behind it remains.
