### Fixed
- Memory guard: swap use alone no longer refuses workers or warns; pressure is low MemAvailable (swap counts only under 2x the floor), PSI full stalls add to the warning line, and the steward warns once per condition naming the idle workers gc stopped (CEL-126).
