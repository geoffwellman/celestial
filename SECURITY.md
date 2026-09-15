# Security policy

## Reporting

Use GitHub's **Report a vulnerability** entry on the repository's Security tab:

https://github.com/geoffwellman/celestial/security/advisories/new

Do not open a public issue containing an exploit, credentials, workspace data
or private history. Include the affected version/commit, prerequisites, impact
and a minimal isolated reproduction. Use synthetic accounts and data. Never
test against somebody else's fleet or published pages.

If a credential was exposed, revoke/rotate it with its provider immediately;
removing a Git line does not invalidate a credential. Avoid putting the secret
itself in the report. Hosted commit refs, discussions, logs, caches and release
assets may need separate remediation.

## Supported versions

Security fixes target the latest public release and current `main`. Older
versions may require upgrading; there is no promised backport schedule or
response-time SLA.

## Trust model

- Celestial is a single-user GNU/Linux control plane, not a sandbox. Agents,
  workspace configuration, skills and installed plugins execute with the
  launching user's privileges and available account permissions.
- Local users/root and users with direct trusted tailnet access are trusted.
  Environment isolation prevents accidental cross-workspace credential reuse;
  it does not hide credentials from the operating-system account running them.
- Private pages and dashboard listeners can control local agents. Exact Host,
  Origin and CSRF checks resist browser cross-origin and DNS-rebinding attacks;
  `/api/session` is accessible to a directly trusted caller. These checks are
  not account authentication. Never expose a private listener through a public
  tunnel or unauthenticated public reverse proxy.
- Private published HTML is trusted same-origin JavaScript, not untrusted
  sandboxed content. Do not publish arbitrary hostile HTML into the private
  control origin. Stored feedback is escaped, but that does not make every
  intentionally executable document safe.
- Only the separate public pages tier is intended for internet sharing. Share
  URLs are bearer capabilities. Expiry/revocation stops future server reads,
  not copies already downloaded by a recipient.
- Cleanup refuses dirty, live or unknown work. Its external Git/herdr checks
  cannot provide an atomic transaction against unrelated manual changes.
  Retain backups; do not use GC as a substitute for durable work storage.
- Fresh-install pins do not make the whole machine reproducible. Existing
  tools, distro packages, transitive dependencies and upstream self-updates
  remain part of the operator's supply-chain responsibility.

Automated hygiene and credential scans are useful backstops, not guarantees
that all private information or vulnerabilities have been detected.
