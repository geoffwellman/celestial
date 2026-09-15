// The one module Canvas UI components import but the registry does not ship
// (`../rect-cache`): every component calls createRectCache(el) and reads
// .current for pointer maths, then .destroy() on teardown. Written here so a
// fetched component compiles, and so nothing of theirs is vendored into this
// repo - see lib/effects.sh for how the components arrive.
//
// Cached rather than measured per event because getBoundingClientRect on
// every pointermove forces layout; a resize/scroll-invalidated cache costs
// nothing and is exactly what the callers assume.
export interface RectCache {
  readonly current: DOMRect;
  destroy(): void;
}

export function createRectCache(el: Element): RectCache {
  let rect = el.getBoundingClientRect();
  let dirty = false;

  const invalidate = () => { dirty = true; };
  const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(invalidate) : null;
  ro?.observe(el);
  addEventListener('scroll', invalidate, { passive: true, capture: true });
  addEventListener('resize', invalidate, { passive: true });

  return {
    get current(): DOMRect {
      if (dirty) { rect = el.getBoundingClientRect(); dirty = false; }
      return rect;
    },
    destroy() {
      ro?.disconnect();
      removeEventListener('scroll', invalidate, { capture: true } as EventListenerOptions);
      removeEventListener('resize', invalidate);
    },
  };
}
