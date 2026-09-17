import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { firstValueFrom } from 'rxjs';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { WorkflowsApi } from './workflows-api.service';

describe('WorkflowsApi', () => {
  let service: WorkflowsApi;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({ imports: [HttpClientTestingModule], providers: [WorkflowsApi] });
    service = TestBed.inject(WorkflowsApi);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('listWorkflows: GET /api/workflows, with and without workspaceRoot', async () => {
    const p1 = firstValueFrom(service.listWorkflows());
    const r1 = httpMock.expectOne((r) => r.url === '/api/workflows');
    expect(r1.request.params.has('workspaceRoot')).toBe(false);
    r1.flush([]);
    await p1;

    const p2 = firstValueFrom(service.listWorkflows('/repo/.ralph-workspace'));
    const r2 = httpMock.expectOne((r) => r.url === '/api/workflows');
    expect(r2.request.params.get('workspaceRoot')).toBe('/repo/.ralph-workspace');
    r2.flush([]);
    await p2;
  });

  it('getWorkflow: GET /api/workflows/:id', async () => {
    const promise = firstValueFrom(service.getWorkflow('bug-fix'));
    const req = httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix');
    expect(req.request.method).toBe('GET');
    req.flush({ id: 'bug-fix' });
    expect((await promise) as { id: string }).toEqual({ id: 'bug-fix' });
  });

  it('createWorkflow: POST /api/workflows', async () => {
    const command = { id: 'x', scope: 'project' as const, pipeline: { stages: [] } };
    const promise = firstValueFrom(service.createWorkflow(command, '/ws'));
    const req = httpMock.expectOne((r) => r.url === '/api/workflows' && r.method === 'POST');
    expect(req.request.body).toEqual(command);
    expect(req.request.params.get('workspaceRoot')).toBe('/ws');
    req.flush({ id: 'x', scope: 'project', sha256: 'h' });
    await promise;
  });

  it('updateWorkflow: PUT /api/workflows/:id', async () => {
    const promise = firstValueFrom(service.updateWorkflow('x', { sha256: 'h', raw: 'y' }));
    const req = httpMock.expectOne((r) => r.url === '/api/workflows/x' && r.method === 'PUT');
    req.flush({ sha256: 'h2' });
    await promise;
  });

  it('customizeWorkflow: POST /api/workflows/:id/customize with targetScope', async () => {
    const promise = firstValueFrom(service.customizeWorkflow('bug-fix', { targetScope: 'global', sourceScope: 'bundled' }));
    const req = httpMock.expectOne((r) => r.url === '/api/workflows/bug-fix/customize' && r.method === 'POST');
    expect(req.request.body).toEqual({ targetScope: 'global', sourceScope: 'bundled' });
    req.flush({ scope: 'global', sha256: 'h', created: true });
    await promise;
  });

  it('patchWorkflowRouting: PATCH /api/workflows/:id/routing with scope query', async () => {
    const promise = firstValueFrom(
      service.patchWorkflowRouting('assessment', 'global', { sha256: 'abc', defaults: { runtime: 'claude' } }, '/ws'),
    );
    const req = httpMock.expectOne((r) => r.url === '/api/workflows/assessment/routing' && r.method === 'PATCH');
    expect(req.request.params.get('scope')).toBe('global');
    expect(req.request.params.get('workspaceRoot')).toBe('/ws');
    req.flush({ scope: 'global', sha256: 'def' });
    await promise;
  });

  it('getWorkflow: passes scope query when requested', async () => {
    const promise = firstValueFrom(service.getWorkflow('x', '/ws', 'global'));
    const req = httpMock.expectOne((r) => r.url === '/api/workflows/x');
    expect(req.request.params.get('scope')).toBe('global');
    req.flush({ id: 'x', scope: 'global' });
    await promise;
  });

  it('deleteWorkflow: DELETE /api/workflows/:id with scope query param', async () => {
    const promise = firstValueFrom(service.deleteWorkflow('x', 'project', '/ws'));
    const req = httpMock.expectOne((r) => r.url === '/api/workflows/x' && r.method === 'DELETE');
    expect(req.request.params.get('scope')).toBe('project');
    expect(req.request.params.get('workspaceRoot')).toBe('/ws');
    req.flush(null);
    await promise;
  });

  it('listWorkflowRuns: GET /api/workflows/:id/runs', async () => {
    const promise = firstValueFrom(service.listWorkflowRuns('x'));
    httpMock.expectOne((r) => r.url === '/api/workflows/x/runs').flush([]);
    await promise;
  });

  it('listRuns: GET /api/workflow-runs with optional workflow/state filters', async () => {
    const p1 = firstValueFrom(service.listRuns());
    const r1 = httpMock.expectOne((r) => r.url === '/api/workflow-runs');
    expect(r1.request.params.has('workflow')).toBe(false);
    r1.flush([]);
    await p1;

    const p2 = firstValueFrom(service.listRuns({ workflow: 'x', state: 'running' }));
    const r2 = httpMock.expectOne((r) => r.url === '/api/workflow-runs');
    expect(r2.request.params.get('workflow')).toBe('x');
    expect(r2.request.params.get('state')).toBe('running');
    r2.flush([]);
    await p2;
  });

  it('getRunStatus: GET /api/workflow-runs/:runId', async () => {
    const promise = firstValueFrom(service.getRunStatus('run-1'));
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1').flush({ schemaVersion: 1, run: {}, stages: [], diagnosis: {}, nextAction: null });
    await promise;
  });

  it('listRuntimes: GET /api/workflow-runtimes', async () => {
    const promise = firstValueFrom(service.listRuntimes());
    httpMock.expectOne('/api/workflow-runtimes').flush([]);
    await promise;
  });

  it('listModels: GET /api/workflow-runtimes/:runtime/models', async () => {
    const promise = firstValueFrom(service.listModels('claude'));
    httpMock.expectOne((r) => r.url === '/api/workflow-runtimes/claude/models').flush([]);
    await promise;
  });

  it('startWorkflow: POST /api/workflows/:id/start', async () => {
    const promise = firstValueFrom(service.startWorkflow('x', { task: 'do it' }));
    const req = httpMock.expectOne((r) => r.url === '/api/workflows/x/start' && r.method === 'POST');
    expect(req.request.body).toEqual({ task: 'do it' });
    req.flush({ runId: 'run-1', logPath: '/tmp/x.log' });
    await promise;
  });

  it('cancelRun: POST /api/workflow-runs/:runId/cancel with an empty body', async () => {
    const promise = firstValueFrom(service.cancelRun('run-1'));
    const req = httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/cancel' && r.method === 'POST');
    expect(req.request.body).toEqual({});
    req.flush({ ok: true });
    await promise;
  });

  it('resumeRun: POST /api/workflow-runs/:runId/resume', async () => {
    const promise = firstValueFrom(service.resumeRun('run-1'));
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/resume' && r.method === 'POST').flush({ ok: true });
    await promise;
  });

  it('listRunActions: GET /api/workflow-runs/:runId/actions', async () => {
    const promise = firstValueFrom(service.listRunActions('run-1'));
    httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/actions').flush([]);
    await promise;
  });

  it('respondRunAction: POST /api/workflow-runs/:runId/actions/respond', async () => {
    const promise = firstValueFrom(service.respondRunAction('run-1', { requestId: 'req-1', decision: 'approve' }));
    const req = httpMock.expectOne((r) => r.url === '/api/workflow-runs/run-1/actions/respond' && r.method === 'POST');
    expect(req.request.body).toEqual({ requestId: 'req-1', decision: 'approve' });
    req.flush({ ok: true });
    await promise;
  });

  it('fetchCapabilities: GET /api/capabilities', async () => {
    const promise = firstValueFrom(service.fetchCapabilities());
    httpMock.expectOne('/api/capabilities').flush({ workflowWrites: true, workflowRuns: true, assistant: true });
    await promise;
  });
});
