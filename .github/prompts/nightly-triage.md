An earlier nightly run opened the OPEN NIGHTLY PRS, simplification PRs, and main has moved on
since. Check that each still makes sense on main as it is now. main is checked out.

For each PR, read `gh pr view N`, `gh pr diff N` and, on main, the code it touches, its callers
and the patterns it follows. Then decide one of:

- keep: the change still fits main. This is the default: when in doubt, keep it.
- close: main made it obsolete or wrong. The code it simplifies is gone or rewritten, main
  already made the same change or solved the problem another way, or main changed the design it
  relies on, so the idea no longer holds.
- redo: the idea still holds, but the diff no longer fits main as it is. For example, main
  changed the code it touches or its callers, renamed what it uses or added a use it misses, so
  merging it as is would break or leave the code inconsistent. A redo makes the same change again
  on a new branch from current main, which CI then tests.

A merge conflict alone, the PR's age or a preference for other work is no reason for either:
conflicts get redone anyway.

To close one, run exactly:
  gh pr close N --delete-branch --comment "<one sentence naming what on main made it obsolete>"

Return the PRs to redo in `redo`, each with a one-sentence `why` naming what changed on main.
Leave it empty if none.
