# CEL-48

`cel fleet` is a batch, not a fan-out. The whole-box read computed every
worker row with five `jq` and up to twelve `git` processes of its own, 278
`jq` and 112 `git` on a single console render, with 62% of the wall clock in
system time - fork and exec for crumbs of work that no network was ever
involved in. The ledger is now read in one `jq` per repo, joined against the
herdr roster in the same program; every git question about a worktree is one
`for-each-ref`, one `status` and at most two `rev-list`, asked once and shared
between the row and the unit's counts. The console's two serial loops over
`cel inbox open` and `cel services` now run their calls together, and a
workspace whose call fails still leaves the others rendered.

The document is unchanged, field for field and in order, and the suite holds
a ceiling on EVERY process the read starts - not just the two tools this work
set out to reduce - with PATH replaced by a counting shim so nothing can run
uncounted. On the fixture: 148 processes for three rows and 193 for twelve,
down to 120 and 129; five processes per extra row become one.
