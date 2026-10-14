### Fixed
- pi profiles routed through the gateway now use the matching Claude provider and `OMP_GATEWAY_TOKEN` environment variable; `cel doctor` reports direct pi Anthropic credential expiry with recovery guidance.
- CLIProxyAPI's Claude `user-agent` now derives from installed `claude --version`, enabling Opus 5.5 without a hard-coded client version.
