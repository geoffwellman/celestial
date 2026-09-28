### Fixed
- `cel gc --box` now frees the docker space its dry run promises: dry run and real run share one selection (every image no container uses, minus the base keep list, plus all build cache); a failed docker delete warns with docker's error and exits non-zero instead of reporting "0 B freed".
