#!/bin/sh
# Celestial wrapper (vendored-skills.yaml): runs the Modern Web Guidance CLI
# fetched at install, with its telemetry to Google always off.
export DISABLE_TELEMETRY=1
exec node "$(dirname "$0")/modern-web.mjs" "$@"
