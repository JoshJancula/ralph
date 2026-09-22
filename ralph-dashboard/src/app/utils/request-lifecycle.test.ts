import { jest } from '@jest/globals';
import {
  RequestLifecycle,
  beginInventoryFetch,
  buildRequestKey,
  isAbortError,
  shouldShowRouteSkeleton,
} from './request-lifecycle';

describe('shouldShowRouteSkeleton', () => {
  it('shows skeleton only on first load', () => {
    expect(shouldShowRouteSkeleton(true, false)).toBe(true);
    expect(shouldShowRouteSkeleton(true, true)).toBe(false);
    expect(shouldShowRouteSkeleton(false, false)).toBe(false);
  });
});

describe('beginInventoryFetch', () => {
  it('sets loading only before the first successful fetch', () => {
    const setLoading = jest.fn();
    beginInventoryFetch(false, setLoading);
    expect(setLoading).toHaveBeenCalledWith(true);
    setLoading.mockClear();
    beginInventoryFetch(true, setLoading);
    expect(setLoading).not.toHaveBeenCalled();
  });
});

describe('buildRequestKey', () => {
  it('orders keys stably regardless of insertion order', () => {
    expect(buildRequestKey({ b: 2, a: 1 })).toBe('a=1&b=2');
    expect(buildRequestKey({ a: 1, b: 2 })).toBe('a=1&b=2');
  });

  it('treats null and undefined as empty string', () => {
    expect(buildRequestKey({ project: null, q: undefined })).toBe('project=&q=');
  });

  it('treats false and zero as literal values', () => {
    expect(buildRequestKey({ active: false, count: 0 })).toBe('active=false&count=0');
  });

  it('returns an empty string for an empty object', () => {
    expect(buildRequestKey({})).toBe('');
  });

  it('includes numbers and booleans without coercing', () => {
    expect(buildRequestKey({ project: 'alpha', limit: 10 })).toBe('limit=10&project=alpha');
  });
});

describe('isAbortError', () => {
  it('returns true for AbortError by name', () => {
    expect(isAbortError({ name: 'AbortError' })).toBe(true);
  });

  it('returns true for ERR_CANCELED code', () => {
    expect(isAbortError({ code: 'ERR_CANCELED' })).toBe(true);
  });

  it('returns true for messages containing abort or cancel', () => {
    expect(isAbortError({ message: 'Request aborted' })).toBe(true);
    expect(isAbortError({ message: 'Operation was canceled' })).toBe(true);
    expect(isAbortError({ message: 'ABORTED by user' })).toBe(true);
  });

  it('returns false for non-abort errors', () => {
    expect(isAbortError({ name: 'TypeError' })).toBe(false);
    expect(isAbortError({ message: 'Failed to load' })).toBe(false);
    expect(isAbortError({ code: 'ECONNREFUSED' })).toBe(false);
  });

  it('returns true for wrapped Angular HttpErrorResponse with abort error', () => {
    expect(isAbortError({ error: { name: 'AbortError' } })).toBe(true);
  });

  it('returns true for deeply nested wrapped abort errors', () => {
    expect(isAbortError({ error: { error: { code: 'ERR_CANCELED' } } })).toBe(true);
  });

  it('returns false for null, primitives, and non-objects', () => {
    expect(isAbortError(null)).toBe(false);
    expect(isAbortError(undefined)).toBe(false);
    expect(isAbortError('AbortError')).toBe(false);
    expect(isAbortError({ name: 'Error' })).toBe(false);
  });
});

describe('RequestLifecycle', () => {
  it('returns a handle with sequential ids', () => {
    const lifecycle = new RequestLifecycle();

    const first = lifecycle.start('plans', 'project=a');
    const second = lifecycle.start('runs', 'run=1');

    expect(first.id).toBeLessThan(second.id);
    expect(first.slot).toBe('plans');
    expect(second.slot).toBe('runs');
    expect(first.signal).toBeInstanceOf(AbortSignal);
    expect(second.signal).toBeInstanceOf(AbortSignal);
  });

  it('cancels prior request when starting the same slot with a new key', () => {
    const lifecycle = new RequestLifecycle();
    const first = lifecycle.start('plans', 'project=a');
    const abortSpy = jest.fn();
    first.signal.addEventListener('abort', abortSpy);

    const second = lifecycle.start('plans', 'project=b');

    expect(abortSpy).toHaveBeenCalledTimes(1);
    expect(first.signal.aborted).toBe(true);
    expect(second.signal.aborted).toBe(false);
  });

  it('isCurrent returns true for the latest handle of the same slot and key', () => {
    const lifecycle = new RequestLifecycle();
    const handle = lifecycle.start('plans', 'project=a');

    expect(lifecycle.isCurrent(handle)).toBe(true);
  });

  it('isCurrent returns false for an outdated handle', () => {
    const lifecycle = new RequestLifecycle();
    const first = lifecycle.start('plans', 'project=a');
    lifecycle.start('plans', 'project=b');

    expect(lifecycle.isCurrent(first)).toBe(false);
  });



  it('isCurrent returns false for a handle from another lifecycle instance', () => {
    const lifecycleA = new RequestLifecycle();
    const lifecycleB = new RequestLifecycle();
    const handle = lifecycleA.start('plans', 'project=a');

    expect(lifecycleB.isCurrent(handle)).toBe(false);
  });

  it('isCurrent returns false when keys do not match', () => {
    const lifecycle = new RequestLifecycle();
    const handle = lifecycle.start('plans', 'project=a');

    expect(lifecycle.isCurrent({ ...handle, key: 'project=b' })).toBe(false);
  });

  it('cancel aborts the signal and removes the controller', () => {
    const lifecycle = new RequestLifecycle();
    const handle = lifecycle.start('plans', 'project=a');

    lifecycle.cancel('plans');

    expect(handle.signal.aborted).toBe(true);
    const next = lifecycle.start('plans', 'project=b');
    expect(next.id).toBeGreaterThan(handle.id);
  });

  it('cancel is safe for an unknown slot', () => {
    const lifecycle = new RequestLifecycle();

    expect(() => lifecycle.cancel('unknown')).not.toThrow();
  });

  it('cancelAll aborts every tracked slot', () => {
    const lifecycle = new RequestLifecycle();
    const a = lifecycle.start('home', 'a');
    const b = lifecycle.start('runs', 'b');

    lifecycle.cancelAll();

    expect(a.signal.aborted).toBe(true);
    expect(b.signal.aborted).toBe(true);
  });

  it('clear removes the controller without aborting', () => {
    const lifecycle = new RequestLifecycle();
    const handle = lifecycle.start('plans', 'project=a');

    lifecycle.clear('plans');

    expect(handle.signal.aborted).toBe(false);
  });

  it('clear is safe for an unknown slot', () => {
    const lifecycle = new RequestLifecycle();

    expect(() => lifecycle.clear('unknown')).not.toThrow();
  });

  it('keeps independent slots isolated', () => {
    const lifecycle = new RequestLifecycle();
    const plans = lifecycle.start('plans', 'project=a');
    const runs = lifecycle.start('runs', 'run=1');

    lifecycle.cancel('plans');

    expect(plans.signal.aborted).toBe(true);
    expect(runs.signal.aborted).toBe(false);
    expect(lifecycle.isCurrent(runs)).toBe(true);
  });
});
