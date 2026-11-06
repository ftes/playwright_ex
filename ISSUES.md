# Issues to fix before release

Places where playwright_ex behaves worse than upstream's JS client. Ids are the `#draft-N` ids
DECISIONS_TABLE.md refers to. Work items and upstream-only problems are in PLAN.md "Later".
Being worked on (2026-11-06): #18, #7, #6, #10b.

## Runtime ordering

- **#18 Latch settled mid-emit**: `Browser._did_close` settles `_closedPromise` in a listener
  step, so `Browser.close!` can return before the `disconnected` listener ran; JS resolves it
  inside the synchronous `emit`. Repro: the skipped stress test "connect: the disconnected
  listener has run when close returns".
- **#7 page_close "should not throw when continuing while page is closing"**: fails under
  full-suite load only. If the close reaches the driver before `route.continue`, the close hangs.
  Check that `Promise.void` returns only after `continue` is sent.
- **#6 HAR `unrouteAll` should stop routeFromHAR**: ~1 in 30 under load for us, never for the JS
  client with the same CDP command order.
- **#10b connect_to_worker console test** (skipped): our evaluate lands ~0.5 ms later than JS's
  after the driver resumes node; fails 5-10%.

## Watch

- **#8 Possibly load-flaky** (seen once each): `locator_query_test.exs:324` (webkit),
  `conn_test.exs:360`, `page_screenshot_test.exs:482`, `page_add_locator_handler_test.exs`
  "should work", `network_backlog_test` "handled routes leave no rows" (63 vs 62 rows, twice
  in full runs). Drop each that stays green on CI until release.
