# OTP runtime backlog (Phase 0)

## Status

The full chromium `mix test` run (2026-11-05) had 4082 tests and 61 failures, 1257 s, with
no stall. Phase 0 fixes since then:

- The `add_init_script` callback tests: 14 fixed. The promise was awaited twice, so it is now a latch.
- `waitForURL` on a frame: the glob is resolved before the url is read.
- Dispose-read, about 35 tests (lead decision (a)): a disposed object keeps its rows until the
  connection closes, so it reads, writes and settles latches as in JS.
- WebSocket `wait_for_event` started from a `once` listener: the facade promise is a latch on
  the receiver, because the listener process exits right after the event.

After rerunning every affected spec file (627 tests), 4 failures are confirmed and 5 tests
fail only under full-suite load. A new full run has not been done yet.

| Group | Failing | Flaky under load |
|---|---|---|
| A | 1 | 1 |
| B | 1 | 2 |
| C | 0 | 1 |
| D | 0 | 0 |
| E | 2 | 1 |

## A: lifecycle and remote
- `library/chromium/chromium_test.exs:763`: hang awaiting the console message. The test helper relies on an API scope holding dispatch (the old baton) to subscribe in the same tick.
- Flaky: `library/page_close_test.exs:229`. `page.close` runs together with `route.continue`, and the 5 s `assert_receive` times out under load. It passes alone.

## B: page and frame
- `page/page_history_test.exs:153`: hang. `page.evaluate(pushState)` never returns while the reload's request is stalled.
- Flaky: `page/page_wait_for_navigation_test.exs:59` and `page/page_wait_for_url_test.exs:53`. Both time out under load; likely the `_loadStates` check-then-subscribe race (see below).

## C: locators, handles and matchers
- Flaky: `page/page_autowaiting_basic_test.exs:77`. The order came out as `route|click|navigated` instead of `route|navigated|click`.

## E: artifacts
- `library/coverage_test.exs:244`: hang in the task that collects coverage of an origin left without a page.
- `library/tracing_test.exs:918`: hang awaiting a console promise. Its subscription assumes the same tick, like the chromium case above.
- Flaky: `page/page_screenshot_test.exs:482`. A reload loop plus a screenshot loop hits the test timeout.

## Cross-cutting (Phase 1 audit)
- **Check-then-subscribe.** JS runs `if (!cond) await waitForEvent(..)` in one tick. Here, dispatch can run in between. See PORTING.md, Traps. Open cases: the `_loadStates` check in `Frame.wait_for_navigation`, and the tests' service-worker and console helpers.
- **Promises awaited twice, or stored in a field, must be latches.** See PORTING.md.
- **Retention.** A closed context keeps about 175 rows until the connection closes (deviation, see `ChannelOwner._retire`).
- **Process-local leak.** The process-local `last_checked` in `to_have_url` leaks one entry per call.
- **Stray messages.** A losing local promise in a race can leave a stray message behind.
