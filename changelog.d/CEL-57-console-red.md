- Fixed: the console suite no longer goes red because a day passed. Its tail,
  digest and timeline are windows on *now*, and the fixtures pinned absolute
  timestamps - so the same unchanged commit passed at merge time and failed
  every run after the window closed. Fixture timestamps are now anchored to
  the moment the test sets up, and a lint fails any `ts` or `mergedAt` fixture
  that carries a frozen date.
