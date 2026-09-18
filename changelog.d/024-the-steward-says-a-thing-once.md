### Added
- The steward says a thing once: every item it raises carries a condition key
  (`cel inbox send --fp`), so a repeat becomes an update on the item already
  open - `cel inbox open` shows `(×12, last 17:35)` - and the steward resolves
  its own item, with a `cleared:` line, when the condition stops being true
