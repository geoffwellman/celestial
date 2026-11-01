# shellcheck shell=bash
# Isolated published-data/SQLite fixtures only: no native CLI, auth, or network.
test_pi_catalog_exact_capability_behavior() {
  node --test "$CEL_ROOT/tests/lib/pi-catalog-behavior.mjs"
}
