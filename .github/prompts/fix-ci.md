This PR needs work: its CI failed, reviewers left findings on it, or both (see CI and FINDINGS).

Read `gh pr view PR`, `gh pr diff PR`, FINDINGS and the CI log, if CI failed, and find the cause.
Follow AGENTS.md and PORTING.md, and compare a failing port or ported test with upstream at the
pin. Tests can't run here: CI runs them on your push. Don't merge or rebase on main.

Fix the findings that hold along with any CI failure, in one commit and one push as below, and
answer every finding in `threads` as FINDINGS says. With CI passing and no finding that holds, push
nothing. If CI failed, end with exactly one of these:

- The PR caused it: fix it, keeping what the PR set out to do, its public behaviour and the
  surrounding code's style. Regenerate "do not edit manually" files through their mix tasks. Don't
  weaken or skip a test to get it green. Run `mix format`, `mix compile --warnings-as-errors`,
  `mix credo` and `mix playwright.parity`, `git add` the files, commit with SUBJECT as the subject, then
  run exactly `git push origin BRANCH`.
- It is unrelated to the PR, like a flaky browser test: push your findings' fix, or with none run
  exactly `git commit --allow-empty -m "Re-run CI"`, then the push above.
- The GIVE UP CONDITION holds: run the GIVE UP command, with your sentence, and answer no findings.
