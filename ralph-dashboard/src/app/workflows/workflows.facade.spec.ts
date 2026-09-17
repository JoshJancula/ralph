import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { WorkspaceSelectorService } from '../services/workspace-selector.service';
import { ErrorDialogService } from '../services/error-dialog.service';
import { WorkflowsFacade } from './workflows.facade';
import type { WorkflowDetail, WorkflowListItem } from './workflow.types';

function fakeErrorDialog(): Pick<ErrorDialogService, 'displayError'> {
  return { displayError: vi.fn().mockResolvedValue(undefined) };
}

function fakeWorkspaceSelector(): Pick<WorkspaceSelectorService, 'selectedWorkspacePath' | 'workspaces' | 'hasLoadedOnce'> {
  return {
    selectedWorkspacePath: () => '/repo',
    workspaces: () => [{ path: '/repo', workspaceRoot: '/repo/.ralph-workspace', projectRoot: '/repo', label: 'repo', exists: true }],
    hasLoadedOnce: () => true,
  } as unknown as Pick<WorkspaceSelectorService, 'selectedWorkspacePath' | 'workspaces' | 'hasLoadedOnce'>;
}

/** Lets a sequential await chain (e.g. openDetail's getWorkflow-then-loadRuns) reach its next HTTP call before the next expectOne. */
async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

const SAMPLE_LIST: readonly WorkflowListItem[] = [{ id: 'bug-fix', scope: 'bundled', overview: 'fix bugs', editable: false }];

const SAMPLE_DETAIL: WorkflowDetail = {
  id: 'bug-fix',
  scope: 'bundled',
  raw: '---\nname: bug-fix\n---\n',
  sha256: 'abc123',
  inspect: {},
  mermaid: 'graph TD',
  unsupportedKeys: ['pipeline.extraField'],
};

describe('WorkflowsFacade', () => {
  let facade: WorkflowsFacade;
  let httpMock: HttpTestingController;

  function flushBootstrapLoads(): void {
    for (const req of httpMock.match((r) => r.url === '/api/workflows' || r.url === '/api/workflow-runtimes')) {
      if (req.request.url === '/api/workflow-runtimes') {
        req.flush([]);
      } else {
        req.flush([]);
      }
    }
  }

  beforeEach(() => {
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [
        WorkflowsFacade,
        { provide: WorkspaceSelectorService, useValue: fakeWorkspaceSelector() },
        { provide: ErrorDialogService, useValue: fakeErrorDialog() },
      ],
    });
    facade = TestBed.inject(WorkflowsFacade);
    httpMock = TestBed.inject(HttpTestingController);
    flushBootstrapLoads();
  });

  afterEach(() => {
    facade.stopRunsPolling();
    facade.stopRunStatusPolling();
    flushBootstrapLoads();
    httpMock.verify();
    vi.useRealTimers();
  });

  it('omits workspaceRoot when no workspace is selected', async () => {
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [
        WorkflowsFacade,
        {
          provide: WorkspaceSelectorService,
          useValue: { selectedWorkspacePath: () => null, workspaces: () => [], hasLoadedOnce: () => true },
        },
        { provide: ErrorDialogService, useValue: fakeErrorDialog() },
      ],
    });
    const unscoped = TestBed.inject(WorkflowsFacade);
    const unscopedHttp = TestBed.inject(HttpTestingController);
    const promise = unscoped.load();
    const req = unscopedHttp.expectOne((r) => r.url === '/api/workflows');
    expect(req.request.params.has('workspaceRoot')).toBe(false);
    req.flush([]);
    unscopedHttp.expectOne((r) => r.url === '/api/workflow-runtimes').flush([]);
    await promise;
    unscopedHttp.verify();
  });

  it('refresh() reloads the list and, when a workflow is selected and not dirty, reopens its detail', async () => {
    facade.selectedId.set('bug-fix');
    facade.editDirty.set(false);
    const promise = facade.refresh();
    httpMock.expectOne((r) => r.url === '/api/workflows' && r.method === 'GET').flush([]);
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix' && r.method === 'GET').flush(SAMPLE_DETAIL);
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs').flush([]);
    await promise;
  });

  it('refresh() does not reopen the detail when editDirty is true', async () => {
    facade.selectedId.set('bug-fix');
    facade.editDirty.set(true);
    const promise = facade.refresh();
    httpMock.expectOne((r) => r.url === '/api/workflows' && r.method === 'GET').flush([]);
    await promise;
    httpMock.expectNone((r) => r.url === '/api/workflows/bug-fix');
  });

  it('refresh() surfaces an error on failure', async () => {
    const promise = facade.refresh();
    httpMock.expectOne((r) => r.url === '/api/workflows' && r.method === 'GET').flush('boom', { status: 500, statusText: 'Server Error' });
    await promise;
    expect(facade.error()).toContain('Failed to refresh workflows');
  });

  it('start() surfaces an error on failure', async () => {
    const promise = facade.start('bug-fix', { task: 'x' });
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/start' && r.method === 'POST').flush('boom', { status: 500, statusText: 'Server Error' });
    expect(await promise).toBeNull();
    expect(facade.error()).toContain('Failed to start workflow');
  });

  it('loadModels() returns [] on a request failure without caching the failure', async () => {
    const promise = facade.loadModels('claude');
    httpMock.expectOne((r) => r.url === '/api/workflow-runtimes/claude/models').flush('boom', { status: 500, statusText: 'Server Error' });
    expect(await promise).toEqual([]);
  });

  it('load() fetches workflows and runtimes, attaching the resolved workspaceRoot', async () => {
    const promise = facade.load();
    const listReq = httpMock.expectOne((r) => r.url === '/api/workflows');
    expect(listReq.request.params.get('workspaceRoot')).toBe('/repo/.ralph-workspace');
    listReq.flush(SAMPLE_LIST);
    const runtimesReq = httpMock.expectOne('/api/workflow-runtimes');
    runtimesReq.flush([{ id: 'claude', installed: true }]);
    await promise;
    expect(facade.workflows()).toEqual(SAMPLE_LIST);
    expect(facade.runtimes()).toEqual([{ id: 'claude', installed: true }]);
    expect(facade.loaded()).toBe(true);
    expect(facade.loading()).toBe(false);
  });

  it('setCatalogSearch filters workflows via filteredWorkflows without re-fetching', async () => {
    const list: readonly WorkflowListItem[] = [
      {
        id: 'plan-delivery',
        scope: 'bundled',
        overview: 'Execute supplied plan',
        editable: false,
        catalog: {
          purpose: 'Execute supplied plan',
          expectedOutcome: 'Independently verified delivery',
          mode: 'dependency',
          stageCount: 5,
          executableStageCount: 3,
          supervisorStageCount: 2,
          requiresSuppliedPlan: true,
          writes: true,
          hasHumanGates: false,
        },
      },
      {
        id: 'human-verified-delivery',
        scope: 'bundled',
        overview: 'Human gates',
        editable: false,
        catalog: {
          purpose: 'Human gates',
          expectedOutcome: 'Independently verified delivery',
          mode: 'dependency',
          stageCount: 8,
          executableStageCount: 5,
          supervisorStageCount: 3,
          requiresSuppliedPlan: false,
          writes: true,
          hasHumanGates: true,
        },
      },
    ];
    const promise = facade.load();
    httpMock.expectOne((r) => r.url === '/api/workflows').flush(list);
    httpMock.expectOne('/api/workflow-runtimes').flush([]);
    await promise;
    facade.setCatalogSearch('supplied plan');
    expect(facade.filteredWorkflows().map((w) => w.id)).toEqual(['plan-delivery']);
    facade.setCatalogSearch('human gates');
    expect(facade.filteredWorkflows().map((w) => w.id)).toEqual(['human-verified-delivery']);
  });

  it('load() surfaces an error and still marks loaded on failure', async () => {
    const promise = facade.load();
    httpMock.expectOne((r) => r.url === '/api/workflows').flush('nope', { status: 500, statusText: 'Server Error' });
    httpMock.expectOne((r) => r.url === '/api/workflow-runtimes').flush([]);
    await promise;
    expect(facade.loaded()).toBe(true);
    expect(facade.error()).toContain('Failed to load workflows');
  });

  it('openDetail() loads the detail and then the run history, clearing editDirty', async () => {
    facade.markEditDirty(true);
    const promise = facade.openDetail('bug-fix');
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix').flush(SAMPLE_DETAIL);
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs').flush([]);
    await promise;
    expect(facade.selected()).toEqual(SAMPLE_DETAIL);
    expect(facade.selectedId()).toBe('bug-fix');
    expect(facade.editDirty()).toBe(false);
  });

  it('runs polling starts when a run is live and stops once every run is terminal', async () => {
    vi.useFakeTimers();
    const openPromise = facade.openDetail('bug-fix');
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix').flush(SAMPLE_DETAIL);
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs').flush([{ runId: 'run-1', workflowId: 'bug-fix', mode: 'dependency', entryKind: 'task', state: 'running', createdAt: 'now', graphRunLink: null }]);
    await openPromise;

    await vi.advanceTimersByTimeAsync(4000);
    const poll = httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs');
    poll.flush([{ runId: 'run-1', workflowId: 'bug-fix', mode: 'dependency', entryKind: 'task', state: 'succeeded', createdAt: 'now', graphRunLink: null }]);
    await Promise.resolve();

    await vi.advanceTimersByTimeAsync(4000);
    httpMock.expectNone((r) => r.url === '/api/workflows/bug-fix/runs');
  });

  it('stopRunsPolling() stops the poll (component-destroy path)', async () => {
    vi.useFakeTimers();
    const openPromise = facade.openDetail('bug-fix');
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix').flush(SAMPLE_DETAIL);
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs').flush([{ runId: 'run-1', workflowId: 'bug-fix', mode: 'dependency', entryKind: 'task', state: 'running', createdAt: 'now', graphRunLink: null }]);
    await openPromise;
    facade.stopRunsPolling();
    await vi.advanceTimersByTimeAsync(10000);
    httpMock.expectNone((r) => r.url === '/api/workflows/bug-fix/runs');
  });

  it('create() posts the command and refreshes the list on success', async () => {
    const promise = facade.create({
      id: 'new-flow',
      scope: 'project',
      pipeline: { stages: [] },
    });
    const postReq = httpMock.expectOne((r) => r.url === '/api/workflows' && r.method === 'POST');
    postReq.flush({ id: 'new-flow', scope: 'project', sha256: 'x' });
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows' && r.method === 'GET').flush([]);
    expect(await promise).toBe(true);
    expect(facade.builderDirty()).toBe(false);
  });

  it('create() returns false and records the diagnostics on a 422', async () => {
    const promise = facade.create({ id: 'broken', scope: 'project', pipeline: { stages: [] } });
    httpMock
      .expectOne((r) => r.url === '/api/workflows' && r.method === 'POST')
      .flush({ error: 'Workflow failed validation', diagnostics: 'Error: bad' }, { status: 422, statusText: 'Unprocessable Entity' });
    expect(await promise).toBe(false);
    expect(facade.error()).toContain('bad');
  });

  it('update() returns "conflict" on a 409 without discarding the selected workflow', async () => {
    facade.selected.set(SAMPLE_DETAIL);
    facade.selectedId.set('bug-fix');
    const promise = facade.update('bug-fix', { sha256: 'stale', raw: 'x' });
    httpMock
      .expectOne((r) => r.url === '/api/workflows/bug-fix' && r.method === 'PUT')
      .flush({ error: 'conflict' }, { status: 409, statusText: 'Conflict' });
    expect(await promise).toBe('conflict');
    expect(facade.selected()).toEqual(SAMPLE_DETAIL);
  });

  it('update() returns "ok" and reloads the workflow on success', async () => {
    const promise = facade.update('bug-fix', { sha256: 'abc123', raw: 'x' });
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix' && r.method === 'PUT').flush({ sha256: 'newsha' });
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows' && r.method === 'GET').flush([]);
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix' && r.method === 'GET').flush(SAMPLE_DETAIL);
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs').flush([]);
    expect(await promise).toBe('ok');
  });

  it('start() marks the workflow as triggering only while in flight', async () => {
    expect(facade.isTriggering('bug-fix')).toBe(false);
    const promise = facade.start('bug-fix', { task: 'do it' });
    expect(facade.isTriggering('bug-fix')).toBe(true);
    httpMock
      .expectOne((r) => r.url === '/api/workflows/bug-fix/start' && r.method === 'POST')
      .flush({ runId: 'run-9', logPath: '/tmp/x.log' });
    await promise;
    expect(facade.isTriggering('bug-fix')).toBe(false);
  });

  it('customize() posts customize and leaves the detail load to the edit route', async () => {
    const promise = facade.customize('bug-fix', { targetScope: 'project', sourceScope: 'bundled' });
    const postReq = httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/customize' && r.method === 'POST');
    expect(postReq.request.body).toEqual({ targetScope: 'project', sourceScope: 'bundled' });
    postReq.flush({ scope: 'project', sha256: 'x', created: true });
    await flushMicrotasks();
    // Both callers navigate to /workflows/:id/edit, whose route subscription is
    // the single detail-load authority. Refreshing the list and reopening the
    // detail here as well made customize a six-request serial waterfall.
    httpMock.expectNone((r) => r.url === '/api/workflows' && r.method === 'GET');
    httpMock.expectNone((r) => r.url === '/api/workflows/bug-fix' && r.method === 'GET');
    httpMock.expectNone((r) => r.url === '/api/workflows/bug-fix/runs');
    expect(await promise).toEqual({ scope: 'project', sha256: 'x', created: true });
  });

  it('customize() returns null and records an error on failure', async () => {
    const promise = facade.customize('bug-fix');
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/customize' && r.method === 'POST').flush({ error: 'nope' }, { status: 409, statusText: 'Conflict' });
    expect(await promise).toBeNull();
    expect(facade.error()).toContain('nope');
  });

  it('remove() succeeds: deletes, refreshes list, and clears selected when it was the deleted workflow', async () => {
    facade.selected.set(SAMPLE_DETAIL);
    facade.selectedId.set('bug-fix');
    const promise = facade.remove('bug-fix', 'project');
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix' && r.method === 'DELETE').flush(null);
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows' && r.method === 'GET').flush([]);
    expect(await promise).toBe(true);
    expect(facade.selected()).toBeNull();
    expect(facade.selectedId()).toBeNull();
  });

  it('remove() returns false and records an error on failure', async () => {
    const promise = facade.remove('bug-fix', 'project');
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix' && r.method === 'DELETE').flush({ error: 'boom' }, { status: 500, statusText: 'Server Error' });
    expect(await promise).toBe(false);
    expect(facade.error()).toContain('boom');
  });

  it('cancelRun() succeeds and reloads run status', async () => {
    const promise = facade.cancelRun('run-1');
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/cancel' && r.method === 'POST').flush({ ok: true });
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1').flush({ schemaVersion: 1, run: { state: 'cancelled' }, stages: [], diagnosis: {}, nextAction: null });
    expect(await promise).toBe(true);
  });

  it('cancelRun() returns false and records an error on failure', async () => {
    const promise = facade.cancelRun('run-1');
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/cancel' && r.method === 'POST').flush({ error: 'no' }, { status: 500, statusText: 'Server Error' });
    expect(await promise).toBe(false);
    expect(facade.error()).toContain('no');
  });

  it('resumeRun() succeeds and reloads run status', async () => {
    const promise = facade.resumeRun('run-1');
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/resume' && r.method === 'POST').flush({ ok: true });
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1').flush({ schemaVersion: 1, run: { state: 'running' }, stages: [], diagnosis: {}, nextAction: null });
    expect(await promise).toBe(true);
  });

  it('resumeRun() returns false and records an error on failure', async () => {
    const promise = facade.resumeRun('run-1');
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/resume' && r.method === 'POST').flush({ error: 'no' }, { status: 500, statusText: 'Server Error' });
    expect(await promise).toBe(false);
  });

  it('respondAction() succeeds and reloads run status', async () => {
    const promise = facade.respondAction('run-1', { requestId: 'req-1', decision: 'approve' });
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/actions/respond' && r.method === 'POST').flush({ ok: true });
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1').flush({ schemaVersion: 1, run: { state: 'running' }, stages: [], diagnosis: {}, nextAction: null });
    expect(await promise).toBe(true);
  });

  it('respondAction() returns false and records an error on failure', async () => {
    const promise = facade.respondAction('run-1', { requestId: 'req-1', decision: 'approve' });
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/actions/respond' && r.method === 'POST').flush({ error: 'no' }, { status: 500, statusText: 'Server Error' });
    expect(await promise).toBe(false);
  });

  it('listRunActions() returns the parsed list on success and [] with an error recorded on failure', async () => {
    const promise = facade.listRunActions('run-1');
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/actions').flush([{ requestId: 'req-1' }]);
    expect(await promise).toEqual([{ requestId: 'req-1' }]);

    const failPromise = facade.listRunActions('run-2');
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-2/actions').flush('boom', { status: 500, statusText: 'Server Error' });
    expect(await failPromise).toEqual([]);
  });

  it('run status polling starts on a live run and stops once terminal or on stopRunStatusPolling()', async () => {
    vi.useFakeTimers();
    const p1 = facade.loadRunStatus('run-1');
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1').flush({ schemaVersion: 1, run: { state: 'running' }, stages: [], diagnosis: {}, nextAction: null });
    await p1;

    await vi.advanceTimersByTimeAsync(3000);
    httpMock
      .expectOne((r) => r.url === '/api/workflow-runs/run-1')
      .flush({ schemaVersion: 1, run: { state: 'succeeded' }, stages: [], diagnosis: {}, nextAction: null });
    await flushMicrotasks();

    await vi.advanceTimersByTimeAsync(3000);
    httpMock.expectNone((r) => r.url === '/api/workflow-runs/run-1');
  });

  it('loadRunStatus() evicts a missing run on 404 without opening the error dialog', async () => {
    vi.useFakeTimers();
    const errorDialog = TestBed.inject(ErrorDialogService) as ReturnType<typeof fakeErrorDialog>;
    facade.runs.set([
      { runId: 'run-missing', workflowId: 'bug-fix', mode: 'dependency', entryKind: 'task', state: 'running', createdAt: 'now', graphRunLink: null },
    ]);
    const live = facade.loadRunStatus('run-missing');
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-missing').flush({ error: 'not found' }, { status: 404, statusText: 'Not Found' });
    await live;
    expect(facade.runStatus()).toBeNull();
    expect(facade.runs()).toEqual([]);
    expect(errorDialog.displayError).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(6000);
    httpMock.expectNone((r) => r.url === '/api/workflow-runs/run-missing');
  });

  it('loadModels() caches per runtime and does not re-request', async () => {
    const first = await Promise.all([
      facade.loadModels('claude'),
      (async () => {
        httpMock.expectOne((r) => r.url === '/api/workflow-runtimes/claude/models').flush([{ id: 'sonnet', label: 'Sonnet' }]);
      })(),
    ]);
    expect(first[0]).toEqual([{ id: 'sonnet', label: 'Sonnet' }]);
    const second = await facade.loadModels('claude');
    expect(second).toEqual([{ id: 'sonnet', label: 'Sonnet' }]);
    httpMock.expectNone((r) => r.url === '/api/workflow-runtimes/claude/models');
  });

  it('formatErrorDetails prefers diagnostics over error, and returns "" for a non-HTTP error', () => {
    expect(facade.formatErrorDetails(new Error('plain'))).toBe('');
  });
});
