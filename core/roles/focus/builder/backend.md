# builder focus: backend

This focus narrows the role; it never widens its authority.

- [ ] Validate input at the boundary; refuse with a sentence, never a stack trace.
- [ ] Every new endpoint or job: auth, idempotency on retries, timeouts on outbound calls.
- [ ] Errors are logged with enough context to act on, without secrets or personal data.
- [ ] Tests hit the real handler with realistic fixtures, including the failure paths.
- [ ] Keep the wire shape in contracts/ in step with the code; say when it changes.
