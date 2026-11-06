# OTP runtime backlog (Phase 2)

Phase 2 fixed the route latches, interception patterns, connect-after-initialize, `Promise.all`
strays, remote connection leak and `_actual_headers` items. What's left:

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
- **HAR `unrouteAll` flake** (browsercontext_har_test "context/page.unrouteAll should stop
  routeFromHAR"): ~1 in 30 under load for us, never for the JS client with the same CDP command
  order; `Page.url` is still about:blank after `unroute_all` returns. No ordering difference found
  in the dispose path; next step is a CDP trace of a failing run (scripts in the round-2 notes).

Possibly load-flaky, to watch: `locator_query_test.exs:324` (webkit), `conn_test.exs:360`
(120 s timeout once in a loaded full run), `page_screenshot_test.exs:482`,
`page_add_locator_handler_test.exs` "should work" (hover with 2 concurrent pages).
