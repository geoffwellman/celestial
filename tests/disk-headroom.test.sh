#!/usr/bin/env bash
# Isolated real-child controller smoke; never uses installed cleanup handlers.
test_disk_headroom_controller() {
  python3 "$CEL_ROOT/tools/disk-headroom/test_controller.py"
}
