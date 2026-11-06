# Issues to fix before release

Places where playwright_ex behaves worse than upstream's JS client. Ids are the `#draft-N` ids
DECISIONS_TABLE.md refers to. Work items and upstream-only problems are in PLAN.md "Later".
Runtime ordering (#18, #7, #6, #10b), memory (#19, #20) and port details (#13, #14) were fixed
on 2026-11-06; OOPIF went to PLAN.md Later (upstream's race too).

## Watch

- **#8 Possibly load-flaky** (seen once each): `locator_query_test.exs:324` (webkit),
  `conn_test.exs:360`, `page_screenshot_test.exs:482`, `page_add_locator_handler_test.exs`
  "should work". Drop each that stays green on CI until release.
