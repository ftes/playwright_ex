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

## Releasing

1. For the first non-RC release, merge the RC sections into `## [Unreleased]` and drop the
   `**RC only:**` entries ([AGENTS.md](AGENTS.md)); the script refuses while they remain.
2. `scripts/release --dry-run <version>` runs the checks (an empty `@` on `main@origin` as last
   fetched, an `## [Unreleased]` with entries, a new tag, a greater version and the driver's
   major.minor) and prints the edits.
3. `scripts/release <version>` commits "Release <version>" (the version, its dated changelog
   section and driver line) and "Start the next release", pushes `main` and tags the first
   commit, which starts `release.yml`. It fetches first and checks again. `RELEASE_REMOTE`
   names another remote than `origin`.
4. Approve the staged release on hex.pm; the workflow then creates the GitHub release.

It runs locally, not as a workflow: only an admin can push to `main` past its ruleset, and a tag
pushed with `GITHUB_TOKEN` starts no workflow. The tag doesn't wait for CI on `main`: the release
commits only change versions and the changelog, and the approval on hex.pm is the gate.
