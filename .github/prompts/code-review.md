Review this pull request like a senior maintainer of this codebase. The PR is checked out; read
whatever you need.

First pick the depth. With an earlier review, tmp/claude-review/increment.diff has what changed
since. Review just the increment, and how it meets the rest of the PR, when it refines the PR
within its design: fixes, follow-ups to findings, local changes. Review the whole PR when the
increment changes its shape: new areas, a changed public API or behaviour, a different approach,
or much of the PR rewritten. Read the whole diff either way. The steps below apply to what you
review.

1. Read AGENTS.md and the files it references for the project's rules, and follow its Reviewing
   guidance. Read the PR description (`gh pr view PR`) and the diff (`git diff BASE...HEAD`).
2. For every changed file, read the surrounding code, the callers and the tests, not just the
   hunks. A bug is usually in how the change meets existing code.
3. Look for real defects: wrong behaviour, unhandled cases, broken invariants, authorization or
   data-exposure holes, races, tests that don't test what they claim, and violations of the
   project's written rules. Use subagents to review large or separate areas in parallel. Also
   review simplicity, consistency and scope: point at the existing code a change duplicates or
   departs from, or at the issue it goes beyond.
4. Verify each candidate before reporting: trace the code path and state the concrete input or
   scenario that fails. Drop anything you cannot substantiate, and skip style, naming and
   formatting nits. Don't ask for handling of edge cases outside the PR's issue; list them in
   the summary as follow-ups. Ported code (`@upstream`) marks only its deviations: an edge case
   it shares with upstream is not a defect of this PR, but a new deviation nothing requires is.
   CI runs `mix lint` (format, credo, compile warnings, docs, Dialyzer), the parity check and
   the browser tests (.github/workflows/elixir.yml): don't run or approximate them, and don't
   comment on what they cover. Review what CI cannot catch: correctness, design, upstream
   fidelity and docs.
5. Don't repeat findings already posted on this PR: tmp/claude-review/comments.md has its
   comments, reviews and review comments by maintainers and Claude.

Post each verified finding as an inline comment on the relevant line
(mcp__github_inline_comment__create_inline_comment, confirmed: true) in Conventional Comments
syntax (https://conventionalcomments.org): start with `<label> [decorations]: <subject>`, then
give the failure scenario and a suggested fix. The label is `issue` (a defect), `suggestion`,
`question`, `nitpick`, `todo`, `thought`, `note` or `praise`; don't post praise alone. Decorate
it `(blocking)` when it must be fixed before merge and `(non-blocking)` otherwise, e.g.
`issue (blocking): ...` or `suggestion (non-blocking): ...`.

Then post one new summary comment per review run with `gh pr comment PR --body-file <file>`.
Open it with a verdict on the whole PR as it stands, counting earlier findings that are still
open: `**Verdict: OK to merge.**` when nothing is blocking, noting any non-blocking ones (e.g.
`**Verdict: OK to merge (2 non-blocking suggestions).**`), otherwise
`**Verdict: Issues found: N blocking, M non-blocking.**`. The counts are of the inline comments'
decorations; follow-ups in the summary don't count. Then say which depth you chose and why, and
in a few sentences what you checked and the most important findings (by their label), or why you
found nothing. After an increment review, cover what changed since the last review and say in a
line whether the earlier findings still hold, without repeating the earlier summary. End the
comment with the MARKER line, verbatim.
