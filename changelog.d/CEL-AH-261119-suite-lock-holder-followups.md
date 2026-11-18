### Fixed
- The suite lock's live holder counts only a FLOCK lock. A POSIX (fcntl) or OFD lock on the same inode, in `/proc/locks` or a process's fdinfo, cannot be what blocks `flock -n`, and is no longer named as the holder.
- The live holder is found on btrfs subvolumes and overlayfs. The lock is identified by its inode plus a descriptor whose link resolves to the lock file's path, and the device is taken from the kernel's own `/proc/locks` and fdinfo lines - never from `stat`'s st_dev, which there differs from the device the kernel prints.
- `tests/run.sh`'s "waiting for the suite lock" lines name the process the kernel says holds the lock - its pid, command, start and directory - instead of the pid the lock file still names, which another tool's `flock <lockfile> <cmd>` never writes.
