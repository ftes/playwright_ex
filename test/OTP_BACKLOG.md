# OTP runtime backlog (Phase 2)

Phase 1 fixed every Phase 0 backlog item and the CI failures on bf8975c0. Most were test ports
that assumed the old runtime's same-tick ordering; they now subscribe first. What's left, found
in the Phase 1 audits:

- **Route `complete` latches** (`route_handler.ex` `_handle_impl`): one settled latch row per
  handled route stays on the page or context until it is disposed. Freeing it needs `stop` to
  read the invocation and arm the latch in one atomic step.
- **`_update_interception_patterns`**: computes and sends patterns in different processes, so a
  concurrent `route()` can send stale patterns. Needs compute-and-send in one step.
- **`connect` after `initialize`**: the remote connection's `close` listener reads the browser
  that `connect_to_browser` stores after the (child connection's) `initialize` reply. A close
  dispatched before that write leaves a browser that never emits `disconnected`; JS has no such
  window. The continuation spans several functions, so `channel_call/5`'s `on_reply` doesn't fit
  as is.
- **Waiter rejection**: JS rejects a waiter synchronously inside `emit`; here it settles in the
  waiter's process, so "rejected before the next emit" isn't guaranteed. The mailbox step only
  sends the event; predicate, race, `dispose` and the facade latch's rejection follow in the
  waiter's process. Closing that needs a blocking mailbox step (the connection waits for the
  waiter's ack, its next await or exit) plus a per-process buffer for events of live subscriptions
  the current await doesn't arm (`wait_for_navigation` holds `loadstate` while awaiting
  `navigated`), else dispatch deadlocks. Even then a `.catch` runs in the awaiting process, so
  `browsertype_connect_test`'s "rejected before disconnected" stays adapted.
- **Stray messages from `Promise.all`** over local asyncs (`serialize_argument_with_callbacks`)
  when one rejects.
- **Remote connections**: the child Conn, its forwarder and ETS table are never stopped after
  close (from code reading); one set leaks per `connect` until the parent connection exits.
- **Harmless**: `Request`/`Response` `_actual_headers` may issue two `raw*Headers` calls.

Possibly load-flaky, to watch: `locator_query_test.exs:324` (webkit), `conn_test.exs:360`
(120 s timeout once in a loaded full run), `page_screenshot_test.exs:482`.
