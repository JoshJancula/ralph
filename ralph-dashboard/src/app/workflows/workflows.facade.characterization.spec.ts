/**
 * Facade characterization for workspace switching (PLAN17). Target behavior is
 * documented in `.ralph-workspace/artifacts/dashboard-global-workflow-customization/DESIGN.md`.
 */
import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { Component, inject } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { WorkspaceSelectorService } from '../services/workspace-selector.service';
import { WorkflowsFacade } from './workflows.facade';
import type { WorkflowDetail } from './workflow.types';

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

const DETAIL_A: WorkflowDetail = {
  id: 'bug-fix',
  scope: 'bundled',
  raw: '---\nname: bug-fix\n---\nfrom A\n',
  sha256: 'sha-a',
  inspect: {},
  mermaid: 'graph TD',
};

@Component({ template: '', standalone: true })
class FacadeHostComponent {
  readonly facade = inject(WorkflowsFacade);
}

describe('WorkflowsFacade characterization (workspace transitions)', () => {
  let facade: WorkflowsFacade;
  let httpMock: HttpTestingController;
  let hostFixture: import('@angular/core/testing').ComponentFixture<FacadeHostComponent>;
  const selectedWorkspacePath = signal<string | null>('/repo-a');
  const hasLoadedOnce = signal(true);
  const workspaces = signal([
    { path: '/repo-a', workspaceRoot: '/repo-a/.ralph-workspace', projectRoot: '/repo-a', label: 'A', exists: true },
    { path: '/repo-b', workspaceRoot: '/repo-b/.ralph-workspace', projectRoot: '/repo-b', label: 'B', exists: true },
  ]);

  function flushListAndRuntimes(): void {
    for (const req of httpMock.match((r) => r.url === '/api/workflows' || r.url === '/api/workflow-runtimes')) {
      req.flush([]);
    }
  }

  beforeEach(() => {
    TestBed.resetTestingModule();
    selectedWorkspacePath.set('/repo-a');
    hasLoadedOnce.set(true);
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule, FacadeHostComponent],
      providers: [
        WorkflowsFacade,
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath,
            workspaces,
            hasLoadedOnce,
          },
        },
      ],
    });
    hostFixture = TestBed.createComponent(FacadeHostComponent);
    facade = hostFixture.componentInstance.facade;
    httpMock = TestBed.inject(HttpTestingController);
    hostFixture.detectChanges();
    flushListAndRuntimes();
  });

  afterEach(() => {
    facade.stopRunsPolling();
    facade.stopRunStatusPolling();
    flushListAndRuntimes();
    for (const req of httpMock.match((r) => r.url.includes('/api/workflows/bug-fix'))) {
      req.flush(DETAIL_A);
    }
    for (const req of httpMock.match((r) => r.url.includes('/api/workflows/bug-fix/runs'))) {
      req.flush([]);
    }
    httpMock.verify();
  });

  it('reloads or clears workflow detail when the selected workspace changes after openDetail', async () => {
    const openPromise = facade.openDetail('bug-fix');
    const detailReq = httpMock.expectOne(
      (r) => r.url === '/api/workflows/bug-fix' && r.params.get('workspaceRoot') === '/repo-a/.ralph-workspace',
    );
    detailReq.flush(DETAIL_A);
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs').flush([]);
    await openPromise;
    expect(facade.selected()?.raw).toContain('from A');

    selectedWorkspacePath.set('/repo-b');
    hostFixture.detectChanges();
    await hostFixture.whenStable();
    await flushMicrotasks();

    httpMock.expectOne((r) => r.url === '/api/workflows' && r.params.get('workspaceRoot') === '/repo-b/.ralph-workspace').flush([]);
    httpMock.expectOne((r) => r.url === '/api/workflow-runtimes').flush([]);

    const reloadReq = httpMock.expectOne(
      (r) => r.url === '/api/workflows/bug-fix' && r.params.get('workspaceRoot') === '/repo-b/.ralph-workspace',
    );
    reloadReq.flush({
      ...DETAIL_A,
      raw: '---\nname: bug-fix\n---\nfrom B\n',
      sha256: 'sha-b',
    });
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs').flush([]);
    await flushMicrotasks();
    expect(facade.selected()?.raw).toContain('from B');
    expect(facade.selected()?.sha256).toBe('sha-b');
  });

  it('drops stale detail when a slower workspace-A response arrives after switching to B', async () => {
    const openPromise = facade.openDetail('bug-fix');
    const detailReq = httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix');
    selectedWorkspacePath.set('/repo-b');
    hostFixture.detectChanges();
    await flushMicrotasks();

    httpMock.expectOne((r) => r.url === '/api/workflows' && r.params.get('workspaceRoot') === '/repo-b/.ralph-workspace').flush([]);
    httpMock.expectOne((r) => r.url === '/api/workflow-runtimes').flush([]);

    const reloadReq = httpMock.expectOne(
      (r) => r.url === '/api/workflows/bug-fix' && r.params.get('workspaceRoot') === '/repo-b/.ralph-workspace',
    );
    reloadReq.flush({ ...DETAIL_A, raw: 'from B wins', sha256: 'sha-b' });
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs').flush([]);
    await flushMicrotasks();

    detailReq.flush(DETAIL_A);
    await flushMicrotasks();
    httpMock.expectNone((r) => r.url === '/api/workflows/bug-fix/runs' && r.request.params.get('workspaceRoot') === '/repo-a/.ralph-workspace');
    await openPromise;

    expect(facade.selected()?.raw).toContain('from B wins');
  });

  it('clears editDirty and stops carrying detail across a workspace switch', async () => {
    const openPromise = facade.openDetail('bug-fix');
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix').flush(DETAIL_A);
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs').flush([]);
    await openPromise;
    facade.markEditDirty(true);

    selectedWorkspacePath.set('/repo-b');
    hostFixture.detectChanges();
    await flushMicrotasks();

    httpMock.expectOne((r) => r.url === '/api/workflows' && r.params.get('workspaceRoot') === '/repo-b/.ralph-workspace').flush([]);
    httpMock.expectOne((r) => r.url === '/api/workflow-runtimes').flush([]);

    expect(facade.editDirty()).toBe(false);

    const reloadReq = httpMock.expectOne(
      (r) => r.url === '/api/workflows/bug-fix' && r.params.get('workspaceRoot') === '/repo-b/.ralph-workspace',
    );
    reloadReq.flush({ ...DETAIL_A, scope: 'project', raw: 'project layer', sha256: 'sha-p' });
    await flushMicrotasks();
    httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/runs').flush([]);
    await flushMicrotasks();
    expect(facade.selected()?.scope).toBe('project');
  });

  it('refuses project customize in all-workspaces mode but allows global customize', async () => {
    selectedWorkspacePath.set(null);
    hostFixture.detectChanges();
    await flushMicrotasks();
    flushListAndRuntimes();

    const projectResult = await facade.customize('bug-fix', { targetScope: 'project', sourceScope: 'bundled' });
    expect(projectResult).toBeNull();
    httpMock.expectNone((r) => r.url.includes('/customize'));

    const globalPromise = facade.customize('bug-fix', { targetScope: 'global', sourceScope: 'bundled' });
    const globalReq = httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/customize');
    expect(globalReq.request.body).toEqual({ targetScope: 'global', sourceScope: 'bundled' });
    globalReq.flush({ scope: 'global', sha256: 'g', created: true });
    await flushMicrotasks();
    // The edit route owns the follow-up detail load; customize no longer refetches.
    httpMock.expectNone((r) => r.url === '/api/workflows');
    httpMock.expectNone((r) => r.url === '/api/workflows/bug-fix');
    expect(await globalPromise).toEqual({ scope: 'global', sha256: 'g', created: true });
  });

  it('does not load workflows until workspace registry has loaded once', async () => {
    TestBed.resetTestingModule();
    hasLoadedOnce.set(false);
    selectedWorkspacePath.set('/repo-a');
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule, FacadeHostComponent],
      providers: [
        WorkflowsFacade,
        {
          provide: WorkspaceSelectorService,
          useValue: { selectedWorkspacePath, workspaces, hasLoadedOnce },
        },
      ],
    });
    const deferredHost = TestBed.createComponent(FacadeHostComponent);
    const deferredFacade = deferredHost.componentInstance.facade;
    const deferredHttp = TestBed.inject(HttpTestingController);
    deferredHost.detectChanges();

    const loadPromise = deferredFacade.load();
    deferredHttp.expectNone((r) => r.url === '/api/workflows');
    await loadPromise;

    hasLoadedOnce.set(true);
    deferredHost.detectChanges();
    await flushMicrotasks();
    deferredHttp.expectOne((r) => r.url === '/api/workflows').flush([]);
    deferredHttp.expectOne((r) => r.url === '/api/workflow-runtimes').flush([]);
    await flushMicrotasks();
    deferredFacade.stopRunsPolling();
    deferredFacade.stopRunStatusPolling();
    deferredHttp.verify();
  });
});
