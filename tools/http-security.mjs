import { randomBytes, timingSafeEqual } from 'node:crypto';

// These are single-user local/tailnet tools, not an authentication system.
// Anyone able to read the trusted private origin can obtain its process token.
// Exact configured authorities, never request/forwarded-header-derived trust.
// A wildcard listener is not a wildcard Host grant: non-loopback names/IPs
// still need to appear in trustedOrigins (comma-separated HTTP(S) origins).
const authority = (value) => {
  if (typeof value !== 'string' || !/^(?:\[[0-9a-f:]+\]|[a-z0-9.-]+)(?::[1-9][0-9]{0,4})?$/i.test(value)) return null;
  try {
    const url = new URL(`http://${value}`);
    const rawHost = value.startsWith('[') ? value.slice(0, value.indexOf(']') + 1) : value.split(':')[0];
    if (url.hostname !== rawHost.toLowerCase() || rawHost.endsWith('.')) return null;
    return value.toLowerCase();
  } catch { return null; }
};

export const controlSecurity = ({ host, port, trustedOrigins = '', csrfToken }) => {
  const bindHost = host.includes(':') && !host.startsWith('[') ? `[${host}]` : host;
  const hosts = new Set();
  const origins = new Set();
  const addListener = (name) => {
    const value = authority(`${name}:${port}`);
    if (!value) throw new Error('invalid HTTP listener authority');
    hosts.add(value);
    if (Number(port) === 80) hosts.add(name.toLowerCase());
    origins.add(new URL(`http://${value}`).origin);
  };
  if (!['0.0.0.0', '[::]'].includes(bindHost)) addListener(bindHost);
  if (/^127\./.test(bindHost) || ['localhost', '[::1]', '0.0.0.0', '[::]'].includes(bindHost)) {
    for (const name of ['localhost', '127.0.0.1', '[::1]']) addListener(name);
  }
  for (const entry of trustedOrigins.split(',').map((s) => s.trim()).filter(Boolean)) {
    let url;
    try { url = new URL(entry); } catch { /* refused below */ }
    if (!url || !['http:', 'https:'].includes(url.protocol) || url.origin !== entry || !authority(url.host)) {
      throw new Error('trusted HTTP origins must be exact http(s)://host[:port] origins without a path');
    }
    hosts.add(url.host);
    if (!url.port) hosts.add(`${url.hostname}:${url.protocol === 'https:' ? 443 : 80}`);
    origins.add(url.origin);
  }
  const token = csrfToken === undefined ? randomBytes(32).toString('base64url') : csrfToken;
  if (!/^[A-Za-z0-9_-]{32,}$/.test(token)) {
    throw new Error('CSRF token override must contain at least 32 URL-safe characters');
  }
  const tokenBytes = Buffer.from(token);
  const sameOrigin = (req) => {
    const site = req.headers['sec-fetch-site'];
    if (site && site !== 'same-origin' && site !== 'none') return false;
    const origin = req.headers.origin;
    if (origin !== undefined) {
      try {
        const url = new URL(origin);
        if (!origins.has(origin)) return false;
        // Both authority and scheme come from explicit configuration. Never
        // infer proxy trust from Forwarded/X-Forwarded-* request headers.
        if (url.host !== new URL(`${url.protocol}//${req.headers.host}`).host) return false;
      } catch { return false; }
    }
    return true;
  };
  const refuse = (res, text) => {
    res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' }).end(text);
    return false;
  };
  return {
    token,
    allow(req, res) {
      res.setHeader('cache-control', 'no-store');
      res.setHeader('x-content-type-options', 'nosniff');
      res.setHeader('referrer-policy', 'same-origin');
      res.setHeader('x-frame-options', 'SAMEORIGIN');
      let count = 0;
      for (let i = 0; i < req.rawHeaders.length; i += 2) {
        if (req.rawHeaders[i].toLowerCase() === 'host') count++;
      }
      const requested = authority(req.headers.host);
      if (count !== 1 || !requested || !hosts.has(requested)) return refuse(res, 'untrusted Host');
      if (req.method === 'GET' || req.method === 'HEAD') return true;
      if (!sameOrigin(req)) return refuse(res, 'cross-origin request refused');
      if (String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase() !== 'application/json') {
        return refuse(res, 'application/json required');
      }
      const supplied = req.headers['x-cel-csrf'];
      if (typeof supplied !== 'string' || supplied.length !== token.length || !/^[A-Za-z0-9_-]+$/.test(supplied) ||
          !timingSafeEqual(Buffer.from(supplied), tokenBytes)) return refuse(res, 'invalid CSRF token; reload the page or fetch /api/session');
      return true;
    },
    session(req, res) {
      if (!sameOrigin(req)) return refuse(res, 'cross-origin request refused');
      res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ csrfToken: token }));
      return true;
    },
  };
};

// Never try to replace headers after a response has started. Callers should
// finish fallible body work before writeHead; this also contains late errors.
export const internalError = (res) => {
  if (res.writableEnded || res.destroyed) return;
  if (res.headersSent) { res.destroy(); return; }
  res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' }).end('internal server error');
};
