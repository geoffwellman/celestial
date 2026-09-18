### Added
- A translator wired into that command line: type a sentence and a small model
  (`console.provider` in `~/.local/share/cel/config.yaml`, endpoints from
  `agents.yaml`) proposes exactly ONE command, which runs only when you press
  Enter again. No key configured means no translation and a console that is
  otherwise fully useful; the model never executes anything
