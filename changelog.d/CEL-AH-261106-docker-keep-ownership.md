### Fixed

- Docker retention now unions the operator-owned legacy keep file with every producer-owned `docker-keep-patterns.d/*.patterns` file. The version-1 safety contract adds `keep_dir`; explicit missing paths, malformed/unreadable declarations and selected symlinks refuse mutation.
- Executor images remain conservatively protected without an explicit executor declaration. Validated current/rollback declarations permit superseded unused executor images to be swept while immutable base prefixes, `cel.keep=true`, other producers and container references still veto removal. Producers publish only their own complete file atomically under the shared image lock; the README documents migration without replacing global operator declarations.
