### Fixed
- `cel gateway rotate-key --status` after an `--abort` killed right after restoring the old key no longer claims an `api-key.next` is still accepted. It says `config.yaml` still accepts a key that is in no key file, and that `--abort` again (or `cel gateway refresh`) removes it. A test now also pins the `CEL_GATEWAY_ROTATE_CRASH_AFTER` test seam as inert outside the suite.
