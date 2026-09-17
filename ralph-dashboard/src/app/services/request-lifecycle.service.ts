import { Injectable, OnDestroy } from '@angular/core';
import { RequestHandle, RequestKeyParts, RequestLifecycle, buildRequestKey } from '../utils/request-lifecycle';

/**
 * Shared request lifecycle for route hubs. Responses are keyed by selected
 * project / query state. Calling start() cancels any prior in-flight request
 * for the same slot; destroy cancels remaining work so route exits drop stale
 * responses. Prefer start() over polling or generation counters alone.
 */
@Injectable({ providedIn: 'root' })
export class RequestLifecycleService implements OnDestroy {
  private readonly lifecycle = new RequestLifecycle();

  ngOnDestroy(): void {
    this.lifecycle.cancelAll();
  }

  start(slot: string, keyParts: RequestKeyParts): RequestHandle {
    return this.lifecycle.start(slot, buildRequestKey(keyParts));
  }

  startWithKey(slot: string, key: string): RequestHandle {
    return this.lifecycle.start(slot, key);
  }

  isCurrent(handle: RequestHandle): boolean {
    return this.lifecycle.isCurrent(handle);
  }

  cancel(slot: string): void {
    this.lifecycle.cancel(slot);
  }

  cancelAll(): void {
    this.lifecycle.cancelAll();
  }
}
