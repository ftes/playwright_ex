CI failed on this PR. The end of the failed steps' log is in tmp/ci-failed.log (tmp/ is gitignored).

Read the log, `gh pr view PR` and `gh pr diff PR`, and find the cause. Follow AGENTS.md and
PORTING.md, and compare a failing port or ported test with upstream at the pin. Tests can't run
here: CI runs them on your push. Don't merge or rebase on main. End with exactly one of these:

- The PR caused it: fix it, keeping what the PR set out to do. Don't weaken or skip a test to get
  it green. Run `mix format`, `mix compile --warnings-as-errors`, `mix credo` and
  `mix playwright.parity`, `git add` the files, commit with "Fix CI: <one imperative sentence>"
  as the subject, then run exactly `git push origin BRANCH`.
- It is unrelated to the PR, like a flaky browser test: run exactly
  `git commit --allow-empty -m "Re-run CI"`, then the push above.
- It needs a redesign of the change, a decision or a skip: run the GIVE UP command, with your
  sentence.

If the system prompt says dependency setup failed (likely transient): stop without closing the PR
or giving up; the next run retries. Only when the failed log shows the same failure did the PR
break its own deps: fix that as above.
