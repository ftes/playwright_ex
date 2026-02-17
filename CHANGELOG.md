# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
<!-- and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). -->

## [Unreleased]
### Added
- `PlaywrightEx.Frame`: `is_visible/2`, `is_checked/2`, `is_disabled/2`, `is_enabled/2`, `is_editable/2`, `get_attribute/2`, `input_value/2`, `text_content/2`, `inner_text/2`, `focus/2`, `dispatch_event/2`, `wait_for_function/2`. #22, [@oliver-kriska]
- `PlaywrightEx.Frame.wait_for_selector/2`: `state` and `strict` options. #22, [@oliver-kriska]
### Fixed
- `PlaywrightEx.Frame.wait_for_selector/2`: crash when `state` is `"hidden"` or `"detached"` (result has no element). #22

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

[530e362]: https://github.com/ftes/playwright_ex/commit/530e36
[fecf965]: https://github.com/ftes/playwright_ex/commit/fecf965
[545bc4d]: https://github.com/ftes/playwright_ex/commit/545bc4d
[7275ef9]: https://github.com/ftes/playwright_ex/commit/7275ef9
[63fc6eb]: https://github.com/ftes/playwright_ex/commit/63fc6eb
