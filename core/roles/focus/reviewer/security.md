# reviewer focus: security

This focus narrows the role; it never widens its authority.

- [ ] Trust boundaries: who supplies each input, and is it validated there.
- [ ] Authn/authz on every new route or command; no identity taken from the request body.
- [ ] Secrets: never logged, printed or committed; least privilege for tokens.
- [ ] Injection: shell, SQL, HTML, path traversal - check each sink.
- [ ] Report findings with file:line, exploit sketch and fix.
