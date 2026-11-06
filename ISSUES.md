# Issues to fix before release

Places where playwright_ex behaves worse than upstream's JS client. Ids are the `#draft-N` ids
DECISIONS_TABLE.md refers to. Work items and upstream-only problems are in PLAN.md "Later".
Runtime ordering (#18, #7, #6, #10b), memory (#19, #20) and port details (#13, #14) were fixed
on 2026-11-06; OOPIF went to PLAN.md Later (upstream's race too). A context the driver re-creates
under a disposed one's guid (`newContextForReuse`) lost its rows when the old one's creator exited,
which left it in `selectors._contextsForSelectors` (seen once shared workers kept drivers across
modules); fixed 2026-11-06.

Nothing open. The #8 watch list (seven tests seen failing once each) stayed green on CI and was
dropped on 2026-11-06.
