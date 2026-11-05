# OTP runtime backlog (Phase 0)

## Status

The full chromium `mix test --warnings-as-errors` run (2026-11-05, final runtime) had 4085
tests and 7 failures, in 196 s with no stall. The old runtime's run took 1257 s and had 61
failures.

Two of the 7 were fixed after the run: `browsercontext_basic_test.exs:88` and `:142`. A
context created in one Task and closed from another was freed when its creator exited, before
the closer read it. A closed context or browser now stays retained until every process that created or closed it has exited. That
leaves 5 failures.

| Group | Failing | Flaky (load) |
|---|---|---|
| A | 2 | 0 |
| B | 1 | 1 |
| C | 0 | 0 |
| D | 0 | 0 |
| E | 1 | 0 |

Tests that failed only under load in earlier runs, and passed in this one:
- `library/page_close_test.exs:229`
- `page/page_wait_for_navigation_test.exs:59`
- `page/page_wait_for_url_test.exs:53`
- `page/page_autowaiting_basic_test.exs:77`
- `page/page_screenshot_test.exs:482`
- `library/tracing_test.exs:918`

Phase 1 should watch them.

## A: lifecycle and remote
- `library/chromium/chromium_test.exs:763` hangs awaiting the console message. Its helper assumes the old behaviour, where an API scope held dispatch, so subscribing happened in the same tick. The fix is to subscribe first (start `Worker.wait_for_event` in a `once :service_worker` listener).
- `library/chromium/extensions_test.exs:74` hangs in `service_worker/1` for the same reason: the list read and the wait are not in one tick.

## B: page and frame
- `page/page_history_test.exs:153` hangs: `page.evaluate(pushState)` never returns while the reload's request is stalled.
- Flaky (load): `page/page_wait_for_url_test.exs:145`. It passes alone and in its file. Under load, the frame navigation can commit between the url check and the `navigated` subscription (a check-then-subscribe race).

## E: artifacts
- `library/coverage_test.exs:244` hangs in the task that collects coverage of an origin left without a page.

## Cross-cutting (Phase 1 audit)
- **Check-then-subscribe races.** JS does `if (!cond) await waitForEvent(..)` in one tick; here dispatch can run in between. See PORTING.md, Traps. Known sites:
  - `Frame.wait_for_url` and the `_loadStates` check in `Frame.wait_for_navigation`;
  - the tests' service-worker and console helpers.
- **Promises awaited twice or stored in a field must be latches.** See PORTING.md.
- **Retention.** A closed context stays readable until the processes that created or closed it have exited; reads after that raise (deviation). A long-lived process keeps about 175 rows per closed context.
- **Process-local leak.** The process-local `last_checked` in `to_have_url` leaks one entry per call.
- **Stray messages.** A losing local promise in a race can leave a stray message.
