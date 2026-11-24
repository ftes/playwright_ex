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

Releases run from a checkout of [ftes/ci](https://github.com/ftes/ci), with `gh` logged in as a
repo admin (to push `main` past its ruleset and create the tag) and `jj` and `elixir` on the PATH:

```sh
# Makes both commits in a clone and prints them; pushes nothing.
release/release.exs playwright_ex --dry-run <version>
release/release.exs playwright_ex <version>
```

It clones this repo into a temporary directory, commits "Release <version>" and "Start the next
release", pushes `main` and tags the first commit. The tag runs CI (`ci.yml`) on the tagged
commit; once every job passed, its publish job stages the release on Hex. Approve it on hex.pm;
the job then creates the GitHub release.

`## [Unreleased]` gathers every change since the last final release, across the release
candidates. For a final release, drop the `**RC only:**` entries first: the script refuses while
they remain. `release/release.exs` lists the conventions it relies on.