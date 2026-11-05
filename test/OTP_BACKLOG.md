# OTP runtime backlog (Phase 0 full chromium run)

Full `mix test` on chromium, 2026-11-05: 4082 tests, 61 failures, 233 skipped, 1257 s, no
stall. Fixed after the run: the 14 `add_init_script` callback tests (latch for a promise
awaited twice) and `page_wait_for_url_test.exs:145` (glob resolved before reading the url).
That leaves 46, listed below.

The main root cause is **dispose-read**: a disposed object's rows are deleted, so reading
its mutable fields raises TargetClosedError. JS reads the last value instead. This one
cause accounts for about 35 of the 46 failures. State flags (`isClosed`, `isConnected`,
`pages`) were patched in Phase 0 with `Heap.get/3`. Fields such as `_browser`, `_video`,
`_mainFrame`, `_tracing` and `_handled` have no known final value, so they need a plan
decision; see the report.

## A: lifecycle and remote
- `library/browsercontext_basic_test.exs:32`: dispose-read, `context.browser()` after close.
- `library/browsercontext_basic_test.exs:256`: dispose-read, `popup.mainFrame()` after close.
- `library/browsertype_connect_test.exs:726` (launchServer, run-server): dispose-read, `page.video()` after close.
- `library/browsertype_connect_test.exs:754` (launchServer, run-server): dispose-read, `page.video()` after close.
- `library/page_close_test.exs:244`: dispose-read, `route.continue` after page close (`_handled`).
- `library/page_event_crash_test.exs:85`: dispose-read, `page.context()` after close.
- `library/chromium/chromium_test.exs:763`: hang awaiting the console message. The test relies on an API scope holding dispatch (old baton) to subscribe in the same tick.
- `library/chromium/extensions_test.exs:129`: hang in `service_worker/1`, which has the same same-tick assumption (`Api.call` no longer blocks dispatch).

## B: page and frame
- `page/page_history_test.exs:153`: hang. `page.evaluate(pushState)` never returns while the reload's request is stalled.
- `page/page_wait_for_navigation_test.exs:59`: timeout under full-suite load only; passes alone. Likely a check-then-subscribe race (see below).
- `page/page_wait_for_url_test.exs:53`: same as above (with commit).

## C: locators, handles and matchers
- `page/page_autowaiting_basic_test.exs:77`: ordering `route|click|navigated`, expected `route|navigated|click`. The navigated listener runs after the click returns.

## D: network
- `library/browsercontext_fetch_test.exs:1323`: dispose-read, `context.request` after context close.
- `library/global_fetch_test.exs:90`, `:483`, `:507`: dispose-read in `APIRequestContext.dispose` on an already disposed context (`fetch.ex:191`).
- `library/unroute_behavior_test.exs:247`, `:258`, `:269`: dispose-read, `route._handled` after page close (`route.ex:211`). The calls should be no-ops.
- `library/web_socket_test.exs:236`, `:257`: TargetClosedError awaiting a `wait_for_event` promise. Its latch was rejected on dispose before the test's await (an await after dispose).
- `library/web_socket_test.exs:278`: "The promise's owner process exited". A shared latch outlived its creator process (the test helper's spawned process).

## E: artifacts
- `library/video_test.exs`, 18 tests (`:98 :114 :135 :172 :233 :258 :282 :310 :351 :367 :382 :401 :424 :449 :464 :479 :639 :671`): dispose-read, `page.video()` after close (`page.ex:316`).
- `library/screencast_test.exs:289`: dispose-read, `page.screencast()` after close.
- `library/coverage_test.exs:244`: hang in the task that collects coverage of an origin left without a page.
- `library/tracing_test.exs:918`: hang awaiting a console promise, with the same same-tick subscription assumption.
- `page/page_screenshot_test.exs:482`: hang, `reload` loop plus `screenshot` loop under load.

## Cross-cutting
- **Check-then-subscribe races.** JS does `if (!cond) await waitForEvent(..)` in one tick. Here, dispatch can run between the read and the subscription. `Frame.wait_for_url` was made robust. `wait_for_navigation`'s `_loadStates` check and the tests' service-worker helpers remain.
- **Uncaught TargetClosedError in listeners.** These came from `Heap.update` on disposed objects. Fixed after the run: `update/3` of a dead object now drops the write.
