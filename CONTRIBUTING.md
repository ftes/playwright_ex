# Contributing

1. `mix setup` installs dependencies, the pinned Playwright driver and Chromium.
2. `mix test`, or `mix check` for CI's lint and one browser's tests (`BROWSER`); CI also runs the
   other browsers, partitioned, and the Selenium and headed tests.
3. Porting rules: [`PORTING.md`](PORTING.md); the why behind the design:
   [`docs/architecture.md`](docs/architecture.md); agent instructions: [`AGENTS.md`](AGENTS.md).

The compatibility floor is Elixir 1.18 on OTP 27 (`.tool-versions.oldest` and `mix.lock.oldest`,
which CI's oldest lane uses). There are no runtime dependencies, so `mix.lock.oldest` holds only the
dev and test ones that lane builds with; a runtime one would be locked at its floor, the lowest
version its requirement in `mix.exs` accepts, which `DependencyFloorsTest` checks. To update it,
copy `.tool-versions.oldest` to `.tool-versions` and `mix.lock.oldest` to `mix.lock`, run
`mix deps.update <dep>`, and keep the lock as `mix.lock.oldest` once `mix deps.get` leaves it
unchanged from an empty `deps/`, as CI runs it. Then restore `.tool-versions` and `mix.lock`.
Renovate never updates `mix.lock.oldest`. When `mix.exs` no longer accepts what it locks (a raised
floor, or a dev dependency's new major), CI's oldest lane fails at setup with "deps.get changed
mix.lock.oldest"; update the lock as above.

## Reviewing

Besides correctness, review a change for simplicity, consistency and scope. This applies to
human and agent reviews alike.

- Prefer the change that removes or shares code over one that adds a parallel path; logic several
  modules repeat belongs in one place.
- Follow how the codebase already does the same thing. A new pattern needs a reason.
- A PR fixes its issue. Edge cases and gaps that predate it are follow-ups: note them
  instead of adding code for them in the PR.

## Releasing

The script needs a jj working copy colocated with git, `gh` logged in as a repo admin (to push
`main` past its ruleset and create the tag), and `curl` and `elixir` on the PATH.

1. For the first non-RC release, merge the RC sections into `## [Unreleased]` and drop the `**RC
   only:**` entries ([AGENTS.md](AGENTS.md)); the script refuses while they remain.
2. `scripts/release --dry-run <version>` runs the checks (an empty `@` on `main@origin` as last
   fetched, an `## [Unreleased]` with entries, a new tag, a greater version and the driver's
   major.minor) and prints the edits.
3. `scripts/release <version>` commits "Release <version>" (the version, its dated changelog
   section and driver line) and "Start the next release", pushes `main` and tags the first commit.
   It fetches first and checks again. `RELEASE_REMOTE` names another remote than `origin`.
4. The tag runs CI (`elixir.yml`) on the tagged commit; once every job passed, its publish job
   stages the release on Hex. Approve it on hex.pm; the job then creates the GitHub release.

It runs locally, not as a workflow: only an admin can push to `main` past its ruleset, and a tag
pushed with `GITHUB_TOKEN` starts no workflow. `scripts/release` runs ftes/ci's
`release/release.exs` at a pinned commit (Renovate bumps it, and CI's `scripts/release --check`
tests each bump against this repo); this repo's settings are `scripts/release_config.exs`.
