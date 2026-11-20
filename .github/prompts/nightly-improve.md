Find the single most valuable improvement to this codebase's simplicity or consistency and open
one pull request for it, the kind a senior maintainer would be glad to merge. Pick it in or
touching FOCUS: each night looks at a different part of the codebase.

The rules for ported, generated and our own code are in AGENTS.md and PORTING.md: shorter ported
code is not simpler, and in ported code an unneeded deviation (PORTING.md, "Rules") is the best
find.

1. Read PORTING.md, docs/architecture.md and enough of the code in FOCUS to know the prevailing
   patterns. Use subagents to survey separate areas in parallel.
2. Look for duplicated logic that belongs in one place, dead code, needless indirection or
   options, and one concept handled or named differently across modules.
3. Rank the candidates by how much simpler or more uniform the code becomes for how little it
   changes, with unneeded deviations in ported code first. Read the callers and tests of the best
   one before committing to it. Skip anything overlapping an OPEN PR in PREVIOUS NIGHTLY PRS or
   repeating a CLOSED one: those were declined, and `why` holds the reasons people gave.
4. Implement that one idea, matching the surrounding code. Prefer a diff that removes more than
   it adds.

Limits: observable public behaviour stays the same, except where removing an unneeded deviation
restores upstream's. No new features, bug fixes, dependency, CI or changelog changes, and no
changes that are only formatting, comments or renames to taste.

Run `mix format`, `mix compile --warnings-as-errors`, `mix credo` and `mix playwright.parity`;
they must pass. Tests can't run here, in place of AGENTS.md's `mix check`: CI runs them on the
PR, and a later nightly run fixes any failure.

If nothing is clearly worth a maintainer's time, stop without pushing and say why. No PR is a
good result; a marginal PR is not.

To publish, write tmp/nightly-pr.md (tmp/ is gitignored): a few sentences on what was
inconsistent or complex and why this is simpler. Commit with one imperative sentence as the
subject (match `git log`), then run exactly:
  git push -u origin BRANCH
  gh pr create --base main --head BRANCH --title "<subject>" --body-file tmp/nightly-pr.md
