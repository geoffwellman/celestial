---
name: publish
description: Publish an HTML page, report, dashboard or any shareable document to this box's celestial pages server. ALWAYS use this instead of the claude.ai Artifact tool - on this machine the Artifact tool is disabled by policy. Use whenever you would create an artifact, HTML report, visualisation, or hand the user a viewable page.
---

# Publishing pages on this box

This box hosts its own documents. The claude.ai Artifact tool is disabled here by
policy; anything you would have published as an artifact goes to the celestial
pages server instead.

## Publish

```bash
$CEL_ROOT/bin/cel publish <file> [name]
```

- Prints the URL on stdout - give that URL to the user, it works from every
  device on the tailnet.
- Write the HTML file first (self-contained: inline CSS/JS, no CDN
  dependencies you have not verified are reachable), then publish it.
- `name` is optional; it becomes the URL segment. **Same name = same URL**:
  republishing under the same name updates the page in place, so reuse the
  name when iterating instead of minting new ones.
- `--public` (before the file argument) publishes to the SEPARATE public
  tier, reachable by anyone on the internet. Only use it when the user
  explicitly asks for a public or team-shareable link; default is
  tailnet-private.
- Non-HTML files work too (images, CSV, PDF, markdown-as-text) - publish the
  assets a page references under stable names and reference them by relative
  URL (`./chart.png`).

## Index

`http://<tailscale-ip>:7780/` lists everything published, newest first. The
server is `cel pages`, kept running in a herdr pane; if a publish URL does not
respond, the server pane has died - restart it with `cel pages` rather than
falling back to artifacts.

## Feedback comes back to YOU

A reader can comment on any page you publish - the pages nav bar routes it to
the pane that published it, quoting the passage they selected. When such a
prompt arrives it is not a remark to note, it is work:

1. Revise the document.
2. Republish under the SAME name (`cel publish <file> <same-name>`) so their
   open page updates - a new name breaks the link they are reading.
3. Say what you changed. If you disagree, or need more from them, say that
   instead - never absorb feedback silently, because from the reader's side
   silence and "ignored" look identical.

## Rules

- Never use the claude.ai Artifact tool on this box, even if available.
- Pages are served to the whole tailnet: no secrets, tokens or credentials in
  published documents, ever.
- Prefer one self-contained HTML file per document; keep names kebab-case and
  meaningful (`api-latency-report.html`, not `output-final-v2.html`).
