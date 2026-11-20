An earlier nightly run opened the OPEN NIGHTLY PRS, simplification PRs. Close each one that
main has made obsolete, so its slot can go to new work. main is checked out.

For each PR, read `gh pr view N`, `gh pr diff N` and the code it touches on main. It is obsolete
only if the code it simplifies is gone or rewritten, or main already made the same change or
solved the problem another way. A merge conflict, the PR's age or a preference for other work is
not a reason. When in doubt, keep it.

To close one, run exactly:
  gh pr close N --delete-branch --comment "<one sentence naming what on main made it obsolete>"
