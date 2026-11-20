The OLD PR is a simplification that now conflicts with main. Redo it on BRANCH.

Read `gh pr view OLD_PR` and `gh pr diff OLD_PR` for what it set out to do, then make the same
change against the code as it is now, keeping what main has changed since, following AGENTS.md
and PORTING.md (generated files are regenerated, never merged by hand). Run `mix format`,
`mix compile --warnings-as-errors`, `mix credo` and `mix playwright.parity`; they must pass. CI
on the new PR runs the test suite.

If the change can't be redone without redesigning it, stop without pushing and say why.

To publish, commit with the old PR's title as the subject, write tmp/nightly-pr.md (the old
description, updated if the change differs; tmp/ is gitignored), then run exactly, in this order:
  git push -u origin BRANCH
  gh pr create --base main --head BRANCH --title "<subject>" --body-file tmp/nightly-pr.md
  gh pr close OLD_PR --delete-branch --comment "Conflicted with main; replaced by <new PR URL>."
