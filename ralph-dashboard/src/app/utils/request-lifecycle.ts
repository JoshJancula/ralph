/**
 * Request lifecycle helpers for cancelling stale fetches and keying responses
 * by selected project / query state.
 *
 * Components own a RequestLifecycle instance (or inject RequestLifecycleService)
 * and call start() whenever filters or workspace selection change. Responses
 * must check isCurrent() before mutating UI state. AbortSignal is passed through
 * to HttpClient so the browser cancels the in-flight request.
 */

export type RequestKeyParts = Record<string, string | number | boolean | null | undefined>;

export interface RequestHandle {
  readonly id: number;
  readonly slot: string;
  readonly key: string;
  readonly signal: AbortSignal;
}

/** Stable, order-independent key from project/query parts. */
export function buildRequestKey(parts: RequestKeyParts): string {
  return Object.keys(parts)
    .sort()
    .map((key) => `${key}=${parts[key] ?? ''}`)
    .join('&');
}

/** Full-page skeleton only before the first successful paint for this view. */
export function shouldShowRouteSkeleton(loading: boolean, hasLoadedOnce: boolean): boolean {
  return loading && !hasLoadedOnce;
}

/** Turn on the loading flag for first fetch; keep showing cached rows on refresh. */
export function beginInventoryFetch(hasLoadedOnce: boolean, setLoading: (value: boolean) => void): void {
  if (!hasLoadedOnce) {
    setLoading(true);
  }
}

export function isAbortError(err: unknown): boolean {
  if (!err || typeof err !== 'object') {
    return false;
  }
  const maybe = err as { name?: string; code?: string; message?: string; error?: unknown };
  if (maybe.name === 'AbortError' || maybe.code === 'ERR_CANCELED') {
    return true;
  }
  if (typeof maybe.message === 'string' && /abort|cancel/i.test(maybe.message)) {
    return true;
  }
  // Angular HttpClient wraps AbortError in HttpErrorResponse
  if (maybe.error && typeof maybe.error === 'object') {
    return isAbortError(maybe.error);
  }
  return false;
}

export class RequestLifecycle {
  private generation = 0;
  private readonly controllers = new Map<string, AbortController>();
  private readonly active = new Map<string, { id: number; key: string }>();

  /** Cancel any in-flight request for `slot`, then open a new keyed handle. */
  start(slot: string, key: string): RequestHandle {
    this.cancel(slot);
    const id = ++this.generation;
    const controller = new AbortController();
    this.controllers.set(slot, controller);
    this.active.set(slot, { id, key });
    return { id, slot, key, signal: controller.signal };
  }

  /** True when this handle is still the latest request for its slot and key. */
  isCurrent(handle: RequestHandle): boolean {
    const current = this.active.get(handle.slot);
    return Boolean(current && current.id === handle.id && current.key === handle.key);
  }

  cancel(slot: string): void {
    const controller = this.controllers.get(slot);
    if (controller) {
      controller.abort();
      this.controllers.delete(slot);
    }
  }

  cancelAll(): void {
    for (const slot of [...this.controllers.keys()]) {
      this.cancel(slot);
    }
  }

  /** Clear active tracking without aborting (e.g. after a successful apply). */
  clear(slot: string): void {
    this.controllers.delete(slot);
  }
}
