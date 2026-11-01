### Fixed

An OpenCode orchestrator no longer fails a message that arrives just after OpenCode reloads an idle project. OpenCode starts a fresh plugin instance for that message, and only the plugin's 3-second background check read the private launch proof, so the request was refused with "launch admission is pending" and the turn was lost even though the proof was still valid. Requests, the user shell and the idle hook now wait for the same single in-flight check before deciding. A missing or untrusted launch proof is still refused, and all of its ownership and identity checks are unchanged.
