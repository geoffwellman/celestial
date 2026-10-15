### Fixed
- The Pi gateway models writer now gives `claude-sonnet-5-5` and `claude-opus-5-5` their native 1M context, 128K output, image input and adaptive thinking. The gateway publishes bare ids, so the 128000/8192 no-reasoning fallback had been overwriting them on every Pi gateway launch.
