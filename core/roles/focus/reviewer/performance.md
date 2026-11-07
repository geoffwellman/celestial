# reviewer focus: performance

This focus narrows the role; it never widens its authority.

- [ ] Find the hot path the change touches and its complexity on realistic sizes.
- [ ] No N+1 queries, unbounded loops or reads of growing files from byte 0.
- [ ] Caches have a bound and an invalidation story.
- [ ] Ask for a measurement before and after when the claim is speed.
- [ ] Memory and disk on this box count too.
