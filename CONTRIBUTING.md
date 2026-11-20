# Contributing

1. `mix setup` installs dependencies, the pinned Playwright driver and Chromium.
2. `mix test`, or `mix check` for CI's lint and one browser's tests (`BROWSER`); CI also runs the
   other browsers, partitioned, and the Selenium and headed tests.
3. Porting rules: [`PORTING.md`](PORTING.md); the why behind the design:
   [`docs/architecture.md`](docs/architecture.md); agent instructions: [`AGENTS.md`](AGENTS.md).

## Reviewing

Besides correctness, review a change for simplicity, consistency and scope. This applies to
human and agent reviews alike.

- Prefer the change that removes or shares code over one that adds a parallel path; logic several
  modules repeat belongs in one place.
- Follow how the codebase already does the same thing. A new pattern needs a reason.
- A PR fixes its issue. Edge cases and gaps that predate it are follow-ups: note them
  instead of adding code for them in the PR.
