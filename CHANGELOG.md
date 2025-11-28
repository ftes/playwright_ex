# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
<!-- and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). -->

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
