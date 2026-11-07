# builder focus: database

This focus narrows the role; it never widens its authority.

- [ ] Migrations are additive and ordered; a destructive step needs an owner decision via the lead.
- [ ] Backfill derived from evidence, never a blanket default that misassigns old rows.
- [ ] Indexes for every new query path; check the plan on realistic volume.
- [ ] Concurrent writers: use transactions or a unique constraint, not read-then-write.
- [ ] Test the migration on a copy with existing data, and its rollback.
