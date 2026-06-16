# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
<!-- and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). -->

## [Unreleased]
### Fixed
- Support the Playwright 1.61 `Frame.expect` wire contract. 1.61 stopped
  returning `%{matches: boolean}` and now signals the assertion outcome by
  success-vs-error: a non-match returns a protocol error carrying
  `error_details`. `Frame.expect/2` now yields a plain `{:ok, boolean}` under
  both 1.60 and 1.61, so `phoenix_test_playwright`'s `assert_has`/`refute_has`
  keep working. `PlaywrightEx.Serialization.deserialize_arg/1` also raises a
  descriptive error on unknown serialized shapes instead of a bare
  `CaseClauseError`. [@oliver-kriska]

## [0.6.1] 2026-06-16
### Added
- Accept all supported options to `Frame.goto`. Commit [8e96071], #49, [@s3cur3]
- `Page.expect_screenshot/2`. Commit [929b90e], #56, [@Wigny]

### Fixed
- Handle `viewport: nil` to disable default viewport. Commit [8139523], #46

## [0.6.0] 2026-05-05
### Added
- `PlaywrightEx.Artifact` for saving and deleting Playwright artifact files. Commit [8178f7c]
- `PlaywrightEx.BrowserContext` clock helpers: `clock_install/2` and `clock_fast_forward/2`. Commit [7b6b977], #30
- `PlaywrightEx.BrowserContext.storage_state/2` and `PlaywrightEx.BrowserContext.set_storage_state/2`. Commit [bcb5b16], #35, [@probably-not]
- `:env` option for local Port transport environment variables. Commit [0095f7f], #34, [@probably-not]
- `PlaywrightEx.Page.bring_to_front/2` to activate a page tab. Commit [7348fa4], #32
### Removed
- Frame `url/2` helper, which is not a supported Playwright server operation. Commit [9490384]
### Fixed
- `:ignore_https_errors` now serializes to Playwright's required `ignoreHTTPSErrors` casing. Commit [80f28be], #45

## [0.5.0] 2026-03-06
### Added
- `PlaywrightEx.Frame`: `is_visible/2`, `is_checked/2`, `is_disabled/2`, `is_enabled/2`, `is_editable/2`, `get_attribute/2`, `input_value/2`, `text_content/2`, `inner_text/2`, `focus/2`, `dispatch_event/2`, `wait_for_function/2`. Commit [8684fda], #22, [@oliver-kriska]
- `PlaywrightEx.Frame.wait_for_selector/2`: `state` and `strict` options. Commit [8684fda], #22, [@oliver-kriska]
- `PlaywrightEx.BrowserContext.add_init_script/2` and `PlaywrightEx.Page.add_init_script/2`. Commit [74e93f6], #23, [@probably-not]
- `PlaywrightEx.unsubscribe/2` and connection-level unsubscribe support. Commit [319a69b]
- `PlaywrightEx.Frame.wait_for_load_state/2` and `PlaywrightEx.Frame.wait_for_url/2` with event-based navigation waiting. Commit [027b0fa]
- Per-frame event recorder process to keep waiter subscriptions continuous across waits. Commit [027b0fa]
- `PlaywrightEx.Page.expect_url/2` for explicit URL expectations on pages. Commit [027b0fa]
- Regex support in argument serialization/deserialization using protocol-native `{r: %{p, f}}` values. Commit [027b0fa]
- `PlaywrightEx.Page.reload/2` to reload current page. Commit [f3c5b21], #25, [@wjrtz]
### Fixed
- `PlaywrightEx.Frame.wait_for_selector/2`: crash when `state` is `"hidden"` or `"detached"` (result has no element). Commit [8684fda], #22
- `PlaywrightEx.BrowserContext.add_init_script/2` and `PlaywrightEx.Page.add_init_script/2`: use `source` parameter name required by Playwright protocol (instead of `content`). Commit [3fd54a1]
- URL regex expectations now send Playwright-compatible string regex flags. Commit [027b0fa]
- Frame waiter exit errors preserve normalized reason atoms in error metadata. Commit [027b0fa]

## [0.4.0] 2026-02-09
### Added
- Support remote Playwright server via websocket. Commit [63fc6eb], [@carsoncall]

## [0.3.2] 2026-01-30
### Fixed
- Typespec bugs. Commit [7275ef9]

## [0.3.1] 2026-01-30
### Added
- Tracing groups in preparation for `PhoenixTest.Playwright.step/3`: `PlaywrightEx.Tracing.group/3`. Commit [545bc4d], [@nathanl]

## [0.3.0] 2025-12-24
### Added
- `PlaywrightEx.Page.mouse_move/2`, `mouse_down/2`, `mouse_up/2` for low-level mouse control. Commit [530e362], [@nathanl]
- `PlaywrightEx.Frame.hover/2` for hovering over elements (supports manual drag operations). Commit [530e362], [@nathanl]
### Fixed
- Serialization of args given to `PlaywrightEx.Frame.evaluate/2`. Commit [fecf965], [@nathanl]

## [0.2.1] 2025-11-28
### Changed
- Suppress node.js errors on termination

## [0.2.0] 2025-11-19
### Changed
- Add typespecs and docs
- Make channel function input and output consistent

## [0.1.2] 2025-11-14
### Changed
- Extract `PlaywrightEx.Supervisor` (spawn `PortServer` outside of `Connection`)

## [0.1.1] 2025-11-14
### Fixed
- Memory leak: Free memory when playwright resource is destroyed (handle `__dispose__` messages)

## [0.1.0] 2025-11-13
### Added
- First draft

[@nathanl]: https://github.com/nathanl
[@carsoncall]: https://github.com/carsoncall
[@oliver-kriska]: https://github.com/oliver-kriska
[@probably-not]: https://github.com/probably-not
[@wjrtz]: https://github.com/wjrtz
[@s3cur3]: https://github.com/s3cur3
[@Wigny]: https://github.com/Wigny

[530e362]: https://github.com/ftes/playwright_ex/commit/530e36
[fecf965]: https://github.com/ftes/playwright_ex/commit/fecf965
[545bc4d]: https://github.com/ftes/playwright_ex/commit/545bc4d
[7275ef9]: https://github.com/ftes/playwright_ex/commit/7275ef9
[63fc6eb]: https://github.com/ftes/playwright_ex/commit/63fc6eb
[74e93f6]: https://github.com/ftes/playwright_ex/commit/74e93f6
[8684fda]: https://github.com/ftes/playwright_ex/commit/8684fda
[3fd54a1]: https://github.com/ftes/playwright_ex/commit/3fd54a1
[319a69b]: https://github.com/ftes/playwright_ex/commit/319a69b
[027b0fa]: https://github.com/ftes/playwright_ex/commit/027b0fa
[f3c5b21]: https://github.com/ftes/playwright_ex/commit/f3c5b21
[7b6b977]: https://github.com/ftes/playwright_ex/commit/7b6b977
[7348fa4]: https://github.com/ftes/playwright_ex/commit/7348fa4
[9490384]: https://github.com/ftes/playwright_ex/commit/9490384
[bcb5b16]: https://github.com/ftes/playwright_ex/commit/bcb5b16
[0095f7f]: https://github.com/ftes/playwright_ex/commit/0095f7f
[80f28be]: https://github.com/ftes/playwright_ex/commit/80f28be
[8178f7c]: https://github.com/ftes/playwright_ex/commit/8178f7c
[8e96071]: https://github.com/ftes/playwright_ex/commit/8e96071
[929b90e]: https://github.com/ftes/playwright_ex/commit/929b90e
[8139523]: https://github.com/ftes/playwright_ex/commit/8139523
