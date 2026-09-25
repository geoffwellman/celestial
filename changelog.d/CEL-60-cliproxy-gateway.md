### Changed

- `cel gateway` now runs on CLIProxyAPI instead of omp's broker and gateway:
  one supervised box service that is both the credential vault and the
  loopback OpenAI/Anthropic surface, with session affinity switched on (it
  defaults to off, and off means a worker switches account mid-conversation),
  an unauthenticated `/healthz` probe, plain model ids, and a `0700` auth-dir
  in the box state directory. `cel gateway status` lists accounts by reading
  those files, so it costs no quota; `cel gateway login <provider>` drives the
  proxy's own OAuth and prints the instruction rather than hanging off a TTY.
  omp stays installed as an agent runtime.
