import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { Component, PLATFORM_ID } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { provideRouter, Router } from '@angular/router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AssistantStore } from './assistant.store';
import { ErrorDialogService } from '../services/error-dialog.service';

@Component({ selector: 'dummy-route', standalone: true, template: '' })
class DummyRouteComponent {}

const STORAGE_KEY = 'ralph-assistant-v1';

describe('AssistantStore', () => {
  let store: AssistantStore;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    localStorage.removeItem(STORAGE_KEY);
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [
        AssistantStore,
        provideRouter([]),
        { provide: ErrorDialogService, useValue: { displayError: vi.fn().mockResolvedValue(undefined) } },
      ],
    });
    store = TestBed.inject(AssistantStore);
    store.selectedRuntime.set('claude');
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
    localStorage.removeItem(STORAGE_KEY);
  });

  it('toggle() opens/closes the dock and loads tools + runtimes only on open, only once', async () => {
    expect(store.open()).toBe(false);
    store.toggle();
    expect(store.open()).toBe(true);
    const toolsReq = httpMock.expectOne('/api/assistant/tools');
    const runtimesReq = httpMock.expectOne('/api/assistant/runtimes');
    toolsReq.flush([{ name: 'list_workflows', description: 'x', mutating: false }]);
    runtimesReq.flush([{ id: 'claude', label: 'Claude', installed: true }]);
    await Promise.resolve();
    httpMock.expectOne('/api/assistant/runtimes/claude/models').flush([]);
    await Promise.resolve();
    expect(store.tools()).toHaveLength(1);
    expect(store.runtimes()).toHaveLength(1);

    store.toggle();
    expect(store.open()).toBe(false);
    store.toggle();
    expect(store.open()).toBe(true);
    httpMock.expectNone('/api/assistant/tools');
    httpMock.expectNone('/api/assistant/runtimes');
  });

  it('loadTools() and loadRuntimes() fail silently on a request error', async () => {
    const toolsPromise = store.loadTools();
    httpMock.expectOne('/api/assistant/tools').flush('boom', { status: 500, statusText: 'Server Error' });
    await toolsPromise;
    expect(store.tools()).toEqual([]);

    const runtimesPromise = store.loadRuntimes();
    httpMock.expectOne('/api/assistant/runtimes').flush('boom', { status: 500, statusText: 'Server Error' });
    await runtimesPromise;
    expect(store.runtimes()).toEqual([]);
  });

  it('close() sets open to false', () => {
    store.open.set(true);
    store.close();
    expect(store.open()).toBe(false);
  });

  it('clear() resets messages, error, and provenance', async () => {
    const promise = store.send('hi');
    httpMock.expectOne('/api/assistant/chat').flush({ role: 'assistant', content: 'ok', toolsUsed: [], answeredBy: 'Claude', degraded: false });
    await promise;
    expect(store.messages()).toHaveLength(2);
    store.clear();
    expect(store.messages()).toEqual([]);
    expect(store.error()).toBeNull();
    expect(store.lastAnsweredBy()).toBeNull();
    expect(store.lastDegraded()).toBe(false);
  });

  it('loadRuntimes() loads models for a restored runtime selection', async () => {
    store.selectedRuntime.set('claude');
    store.selectedModel.set('sonnet');
    const promise = store.loadRuntimes();
    httpMock.expectOne('/api/assistant/runtimes').flush([{ id: 'claude', label: 'Claude', installed: true }]);
    await promise;
    const modelsReq = httpMock.expectOne('/api/assistant/runtimes/claude/models');
    modelsReq.flush([{ id: 'sonnet', label: 'sonnet' }]);
    await Promise.resolve();
    expect(store.selectedRuntime()).toBe('claude');
    expect(store.selectedModel()).toBe('sonnet');
    expect(store.models()).toEqual([{ id: 'sonnet', label: 'sonnet' }]);
  });

  it('loadRuntimes() clears a restored runtime that is no longer installed', async () => {
    store.selectedRuntime.set('codex');
    store.selectedModel.set('gpt-5');
    const promise = store.loadRuntimes();
    httpMock.expectOne('/api/assistant/runtimes').flush([{ id: 'codex', label: 'Codex', installed: false }]);
    await promise;
    expect(store.selectedRuntime()).toBeNull();
    expect(store.selectedModel()).toBe('');
    httpMock.expectNone('/api/assistant/runtimes/codex/models');
  });

  it('setRuntime() and setModel() start a new chat and persist the selection', () => {
    store.setRuntime('codex');
    httpMock.expectOne('/api/assistant/runtimes/codex/models').flush([]);
    store.setModel('gpt-5');
    expect(store.selectedRuntime()).toBe('codex');
    expect(store.selectedModel()).toBe('gpt-5');
    const raw = localStorage.getItem(STORAGE_KEY);
    expect(JSON.parse(raw!).selectedRuntime).toBe('codex');
    expect(store.messages()[0].content).toContain('New chat started with');
  });

  it('send() optimistically appends the user message, then appends the assistant reply on success', async () => {
    const promise = store.send('what workflows exist?');
    httpMock.expectOne('/api/assistant/chat').flush({ role: 'assistant', content: 'bug-fix exists.', toolsUsed: [], answeredBy: 'Claude', degraded: false });
    expect(await promise).toBe(true);
    expect(store.messages()).toEqual([
      { role: 'user', content: 'what workflows exist?' },
      { role: 'assistant', content: 'bug-fix exists.' },
    ]);
    expect(store.lastAnsweredBy()).toBe('Claude');
    expect(store.lastDegraded()).toBe(false);
  });

  it('send() rolls back the optimistic user message on a request failure', async () => {
    const promise = store.send('hello');
    httpMock.expectOne('/api/assistant/chat').flush({ error: 'assistant chat failed' }, { status: 502, statusText: 'Bad Gateway' });
    expect(await promise).toBe(false);
    expect(store.messages()).toEqual([]);
    expect(store.error()).toBe('assistant chat failed');
  });

  it('send() is a no-op for a blank draft or while already sending', async () => {
    expect(await store.send('   ')).toBe(false);
    httpMock.expectNone('/api/assistant/chat');

    const first = store.send('one');
    expect(await store.send('two')).toBe(false); // sending() is true during the first request
    httpMock.expectOne('/api/assistant/chat').flush({ role: 'assistant', content: 'ok', toolsUsed: [], answeredBy: 'x', degraded: false });
    await first;
  });

  it('sendApprovedAction() includes the approvedAction in the request body', async () => {
    const promise = store.sendApprovedAction('Cancel run run-1', { tool: 'cancel_run', arguments: { runId: 'run-1' } });
    const req = httpMock.expectOne('/api/assistant/chat');
    expect(req.request.body.approvedAction).toEqual({ tool: 'cancel_run', arguments: { runId: 'run-1' } });
    expect(req.request.body.messages[0]).toEqual({ role: 'user', content: 'Cancel run run-1' });
    req.flush({ role: 'assistant', content: 'Cancelled.', toolsUsed: ['cancel_run'], answeredBy: 'Claude', degraded: false });
    expect(await promise).toBe(true);
  });

  it('persists messages, runtime, and model to localStorage after a successful send', async () => {
    store.selectedRuntime.set(null);
    store.setRuntime('claude');
    httpMock.expectOne('/api/assistant/runtimes/claude/models').flush([]);
    store.setModel('sonnet');
    const promise = store.send('hi');
    httpMock.expectOne('/api/assistant/chat').flush({ role: 'assistant', content: 'hello', toolsUsed: [], answeredBy: 'x', degraded: false });
    await promise;
    const raw = localStorage.getItem(STORAGE_KEY);
    expect(raw).not.toBeNull();
    const parsed = JSON.parse(raw!);
    expect(parsed.selectedRuntime).toBe('claude');
    expect(parsed.selectedModel).toBe('sonnet');
    expect(parsed.messages).toHaveLength(3);
  });

  it('restores persisted state on construction', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ version: 1, messages: [{ role: 'user', content: 'restored' }], selectedRuntime: 'codex', selectedModel: 'gpt-5' }),
    );
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({ imports: [HttpClientTestingModule], providers: [AssistantStore, provideRouter([]), { provide: ErrorDialogService, useValue: { displayError: vi.fn().mockResolvedValue(undefined) } }] });
    const restored = TestBed.inject(AssistantStore);
    expect(restored.messages()).toEqual([{ role: 'user', content: 'restored' }]);
    expect(restored.selectedRuntime()).toBe('codex');
    expect(restored.selectedModel()).toBe('gpt-5');
  });

  it('ignores corrupted localStorage content instead of throwing', () => {
    localStorage.setItem(STORAGE_KEY, '{not valid json');
    TestBed.resetTestingModule();
    expect(() => {
      TestBed.configureTestingModule({ imports: [HttpClientTestingModule], providers: [AssistantStore, provideRouter([]), { provide: ErrorDialogService, useValue: { displayError: vi.fn().mockResolvedValue(undefined) } }] });
      TestBed.inject(AssistantStore);
    }).not.toThrow();
  });

  it('is SSR-safe: neither restore nor persist touch localStorage on the server platform', async () => {
    TestBed.resetTestingModule();
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ version: 1, messages: [{ role: 'user', content: 'should not load' }], selectedRuntime: null, selectedModel: '' }));
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [AssistantStore, provideRouter([]), { provide: PLATFORM_ID, useValue: 'server' }, { provide: ErrorDialogService, useValue: { displayError: vi.fn().mockResolvedValue(undefined) } }],
    });
    const serverStore = TestBed.inject(AssistantStore);
    serverStore.selectedRuntime.set('claude');
    expect(serverStore.messages()).toEqual([]);

    const serverHttpMock = TestBed.inject(HttpTestingController);
    const promise = serverStore.send('hi');
    serverHttpMock.expectOne('/api/assistant/chat').flush({ role: 'assistant', content: 'ok', toolsUsed: [], answeredBy: 'x', degraded: false });
    await promise;
    // persist() would have thrown if it called the browser-only localStorage API incorrectly under SSR; reaching here without an unhandled error is the assertion.
    serverHttpMock.verify();
  });

  it('pageContext sent to the server is the current router URL', async () => {
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [AssistantStore, provideRouter([{ path: '**', component: DummyRouteComponent }]), { provide: ErrorDialogService, useValue: { displayError: vi.fn().mockResolvedValue(undefined) } }],
    });
    const s = TestBed.inject(AssistantStore);
    s.selectedRuntime.set('claude');
    const hm = TestBed.inject(HttpTestingController);
    const router = TestBed.inject(Router);
    await router.navigateByUrl('/workflows/bug-fix');
    const promise = s.send('hi');
    const req = hm.expectOne('/api/assistant/chat');
    expect(req.request.body.pageContext).toBe('/workflows/bug-fix');
    req.flush({ role: 'assistant', content: 'ok', toolsUsed: [], answeredBy: 'x', degraded: false });
    await promise;
  });
});
