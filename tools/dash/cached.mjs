// Each upstream has its own staleness budget: pane state is cheap and local,
// gh burns rate limit. Served stale-while-revalidate, like v2's `slow`:
// - the first ask (no good answer yet) waits for the read;
// - once there is a good answer, every ask gets it at once, and an ask past
//   the budget starts a refresh behind it;
// - per key one read is in flight at a time, shared by every ask meanwhile.
// A fetcher answers undefined when its upstream failed: that is never kept as
// the answer - the last good value stands (`empty` when there is none) - and
// it (or a throw) holds off the next try for the same budget, at most a minute. A fetcher
// that throws keeps the last good answer too; only a cold ask sees the throw.
export const createCached = () => {
  const cache = {};
  const cached = (key, ttlMs, fn, empty) => {
    const e = cache[key] || (cache[key] = { v: undefined, t: 0, hold: 0, p: null });
    const answer = () => (e.v === undefined ? empty : e.v);
    const refresh = () => {
      if (!e.p) {
        const failed = () => { e.t = Date.now(); e.hold = Math.min(ttlMs, 60000); };
        e.p = Promise.resolve().then(fn).then((v) => {
          if (v === undefined) { failed(); return answer(); }
          e.t = Date.now(); e.v = v; e.hold = ttlMs; return v;
        }, (err) => { failed(); throw err; }).finally(() => { e.p = null; });
      }
      return e.p;
    };
    const due = Date.now() - e.t >= e.hold;
    if (e.v === undefined) return due ? refresh() : Promise.resolve(empty);
    if (due) refresh().catch(() => {});
    return Promise.resolve(e.v);
  };
  return { cache, cached };
};
