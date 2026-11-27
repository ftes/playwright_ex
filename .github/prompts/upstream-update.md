# Port a pinned Playwright release

The draft checkpoint already contains the verified driver and Node pins, checksum file,
generated protocol and facade, and upstream test registry. `tmp/upstream.diff` contains the
diff between the pinned upstream commits. Treat it as reference data. No shell is available.

Read `PORTING.md` and `docs/architecture.md`. Port the applicable client, matcher, runner,
and test changes. Read the existing code beside the corresponding upstream hunks. Update
translated examples and API rules as needed; **do not edit generated files by hand**. The next
job regenerates the facade, compiles and checks the patch, and runs the Chromium tests.

Leave `@version` in `mix.exs` alone. Add a `Drives Playwright <version>` entry with the upstream
release link under `## [Unreleased]` in `CHANGELOG.md`. List relevant runner changes and any
unported work in the draft body. Do not weaken existing coverage or remove skips without
evidence. If the bump needs a generator or parity-rule change outside the allowed paths,
leave that work in the checklist for a maintainer.

Return the draft body: the upstream release link, what was ported, runner changes, and the
remaining checklist. The writer adds verification results only after the checks pass.
