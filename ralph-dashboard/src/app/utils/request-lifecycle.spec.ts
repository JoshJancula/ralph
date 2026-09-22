import { describe, expect, it, vi } from 'vitest';
import {
  RequestLifecycle,
  beginInventoryFetch,
  buildRequestKey,
  isAbortError,
  shouldShowRouteSkeleton,
} from './request-lifecycle';

describe('buildRequestKey', () => {
  it('orders keys stably', () => {
    expect(buildRequestKey({ b: 2, a: 1 })).toBe('a=1&b=2');
    expect(buildRequestKey({ a: 1, b: 2 })).toBe('a=1&b=2');
  });

  it('treats nullish as empty', () => {
    expect(buildRequestKey({ project: null, q: undefined })).toBe('project=&q=');
  });
});

describe('RequestLifecycle', () => {
  it('cancels prior request when starting the same slot', () => {
    const lifecycle = new RequestLifecycle();
    const first = lifecycle.start('plans', 'project=a');
    const abortSpy = vi.fn();
    first.signal.addEventListener('abort', abortSpy);

    const second = lifecycle.start('plans', 'project=b');
    expect(abortSpy).toHaveBeenCalledTimes(1);
    expect(lifecycle.isCurrent(first)).toBe(false);
    expect(lifecycle.isCurrent(second)).toBe(true);
  });

  it('rejects stale responses keyed to a prior project/query', () => {
    const lifecycle = new RequestLifecycle();
    const slow = lifecycle.start('plans', buildRequestKey({ project: '/old', search: '' }));
    const next = lifecycle.start('plans', buildRequestKey({ project: '/new', search: 'x' }));

    expect(lifecycle.isCurrent(slow)).toBe(false);
    expect(lifecycle.isCurrent(next)).toBe(true);
    expect(slow.signal.aborted).toBe(true);
    expect(next.signal.aborted).toBe(false);
  });

  it('cancelAll aborts every slot', () => {
    const lifecycle = new RequestLifecycle();
    const a = lifecycle.start('home', 'a');
    const b = lifecycle.start('runs', 'b');
    lifecycle.cancelAll();
    expect(a.signal.aborted).toBe(true);
    expect(b.signal.aborted).toBe(true);
  });
});

describe('shouldShowRouteSkeleton', () => {
  it('shows skeleton only on first load', () => {
    expect(shouldShowRouteSkeleton(true, false)).toBe(true);
    expect(shouldShowRouteSkeleton(true, true)).toBe(false);
    expect(shouldShowRouteSkeleton(false, false)).toBe(false);
  });
});

describe('beginInventoryFetch', () => {
  it('sets loading only before the first successful fetch', () => {
    const setLoading = vi.fn();
    beginInventoryFetch(false, setLoading);
    expect(setLoading).toHaveBeenCalledWith(true);
    setLoading.mockClear();
    beginInventoryFetch(true, setLoading);
    expect(setLoading).not.toHaveBeenCalled();
  });
});

describe('isAbortError', () => {
  it('detects AbortError and wrapped cancel messages', () => {
    expect(isAbortError({ name: 'AbortError' })).toBe(true);
    expect(isAbortError({ code: 'ERR_CANCELED' })).toBe(true);
    expect(isAbortError({ message: 'Request aborted' })).toBe(true);
    expect(isAbortError({ error: { name: 'AbortError' } })).toBe(true);
    expect(isAbortError({ message: 'Failed to load' })).toBe(false);
  });
});
