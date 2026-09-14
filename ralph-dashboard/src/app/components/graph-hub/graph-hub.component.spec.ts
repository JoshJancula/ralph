import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';

import type { GraphRunDetail, GraphRunsResponse } from '../../services/api.service';
import { GraphHubComponent } from './graph-hub.component';

// Fixture: a completed run with two nodes
const completedRunDetail: GraphRunDetail = {
  namespace: 'my-graph',
  runId: 'run-20260101T000000Z-0-abc123',
  run: {
    schemaVersion: 1,
    ralphVersion: '1.0.0',
    runId: 'run-20260101T000000Z-0-abc123',
    planPath: '/proj/my-graph.plan.md',
    graphSha: 'deadbeef',
    startedAt: '2026-01-01T00:00:00Z',
    status: 'succeeded',
    maxParallel: 2,
  },
  nodes: [
    {
      nodeId: 'source',
      status: 'succeeded',
      attempts: [
        {
          attemptId: 'source-run-abc-1',
          outcome: 'succeeded',
          exitCode: 0,
          startedAt: '2026-01-01T00:00:00Z',
          finishedAt: '2026-01-01T00:00:10Z',
          runtime: 'claude',
          role: 'research',
          modelSource: 'runtime saved/default',
          nativeSubagents: 'inherit',
        },
      ],
      lastAttemptId: 'source-run-abc-1',
      runtime: 'claude',
      role: 'research',
      modelSource: 'runtime saved/default',
      nativeSubagents: 'inherit',
    },
    {
      nodeId: 'analyze',
      status: 'succeeded',
      attempts: [
        {
          attemptId: 'analyze-run-abc-1',
          outcome: 'succeeded',
          exitCode: 0,
          startedAt: '2026-01-01T00:00:12Z',
          finishedAt: '2026-01-01T00:00:25Z',
          runtime: 'cursor',
          nativeSubagents: 'off',
        },
      ],
      lastAttemptId: 'analyze-run-abc-1',
      runtime: 'cursor',
      nativeSubagents: 'off',
    },
  ],
  graph: {
    schemaVersion: 1,
    ralphVersion: '1.0.0',
    name: 'my-graph',
    namespace: 'my-graph',
    maxParallel: 2,
    failurePolicy: 'drain',
    nodes: [
      {
        id: 'source',
        type: 'agent',
        dependsOn: [],
        derivedFrom: 'stage',
        stage: { id: 'source', runtime: 'claude', role: 'research', _inlineTodos: [] },
      },
      {
        id: 'analyze',
        type: 'agent',
        dependsOn: ['source'],
        derivedFrom: 'stage',
        stage: { id: 'analyze', runtime: 'cursor', _inlineTodos: [] },
      },
    ],
    edges: [{ from: 'source', to: 'analyze', reasons: ['declared'] }],
  },
};

// Fixture: an in-progress run with a running node
const inProgressRunDetail: GraphRunDetail = {
  namespace: 'my-graph',
  runId: 'run-20260102T000000Z-0-def456',
  run: {
    schemaVersion: 1,
    ralphVersion: '1.0.0',
    runId: 'run-20260102T000000Z-0-def456',
    planPath: '/proj/my-graph.plan.md',
    graphSha: 'deadbeef',
    startedAt: '2026-01-02T00:00:00Z',
    status: 'running',
    maxParallel: 2,
  },
  nodes: [
    {
      nodeId: 'source',
      status: 'succeeded',
      attempts: [
        {
          attemptId: 'source-run-def-1',
          outcome: 'succeeded',
          exitCode: 0,
          startedAt: '2026-01-02T00:00:00Z',
          finishedAt: '2026-01-02T00:00:08Z',
          runtime: 'claude',
        },
      ],
      lastAttemptId: 'source-run-def-1',
    },
    {
      nodeId: 'analyze',
      status: 'running',
      attempts: [
        {
          attemptId: 'analyze-run-def-1',
          outcome: 'running',
          startedAt: '2026-01-02T00:00:10Z',
          runtime: 'cursor',
        },
      ],
      lastAttemptId: 'analyze-run-def-1',
    },
  ],
  graph: completedRunDetail.graph,
};

const runsResponse: GraphRunsResponse = {
  runs: [
    {
      namespace: 'my-graph',
      runId: 'run-20260102T000000Z-0-def456',
      isLatest: true,
      status: 'running',
      startedAt: '2026-01-02T00:00:00Z',
      nodeCount: 2,
    },
    {
      namespace: 'my-graph',
      runId: 'run-20260101T000000Z-0-abc123',
      isLatest: false,
      status: 'succeeded',
      startedAt: '2026-01-01T00:00:00Z',
      nodeCount: 2,
    },
  ],
};

describe('GraphHubComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [GraphHubComponent, HttpClientTestingModule, RouterTestingModule],
    }).compileComponents();

    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('renders the run list after loading', fakeAsync(() => {
    const fixture = TestBed.createComponent(GraphHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/graph-runs');
    req.flush(runsResponse);
    tick();
    fixture.detectChanges();

    const compiled: HTMLElement = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('.run-list')).not.toBeNull();
    const cards = compiled.querySelectorAll('.run-card');
    expect(cards.length).toBe(2);
    expect(compiled.textContent).toContain('my-graph');
  }));

  it('renders node table and mermaid block for a completed run', fakeAsync(() => {
    const fixture = TestBed.createComponent(GraphHubComponent);
    const component = fixture.componentInstance;
    fixture.detectChanges();

    // Flush the runs list
    const runsReq = httpMock.expectOne('/api/graph-runs');
    runsReq.flush(runsResponse);
    tick();
    fixture.detectChanges();

    // Select the completed run
    component.selectRun(runsResponse.runs[1]);
    fixture.detectChanges();

    const detailReq = httpMock.expectOne(
      `/api/graph-runs/${encodeURIComponent('my-graph')}/${encodeURIComponent('run-20260101T000000Z-0-abc123')}`,
    );
    detailReq.flush(completedRunDetail);
    tick();
    fixture.detectChanges();

    const compiled: HTMLElement = fixture.nativeElement as HTMLElement;

    // Node table should be present
    const table = compiled.querySelector('.node-table');
    expect(table).not.toBeNull();

    // Both nodes should appear in table
    expect(compiled.textContent).toContain('source');
    expect(compiled.textContent).toContain('analyze');
    expect(compiled.textContent).toContain('succeeded');

    // Mermaid pre block should be present and non-empty
    const pre = compiled.querySelector('.dag-pre');
    expect(pre).not.toBeNull();
    expect(pre?.textContent).toContain('flowchart TD');
    expect(pre?.textContent).toContain('source');
    expect(pre?.textContent).toContain('analyze');
  }));

  it('renders node table and mermaid block for an in-progress run without error', fakeAsync(() => {
    const fixture = TestBed.createComponent(GraphHubComponent);
    const component = fixture.componentInstance;
    fixture.detectChanges();

    const runsReq = httpMock.expectOne('/api/graph-runs');
    runsReq.flush(runsResponse);
    tick();
    fixture.detectChanges();

    // Select the in-progress run
    component.selectRun(runsResponse.runs[0]);
    fixture.detectChanges();

    const detailReq = httpMock.expectOne(
      `/api/graph-runs/${encodeURIComponent('my-graph')}/${encodeURIComponent('run-20260102T000000Z-0-def456')}`,
    );
    detailReq.flush(inProgressRunDetail);
    tick();
    fixture.detectChanges();

    const compiled: HTMLElement = fixture.nativeElement as HTMLElement;

    const table = compiled.querySelector('.node-table');
    expect(table).not.toBeNull();
    expect(compiled.textContent).toContain('running');

    const pre = compiled.querySelector('.dag-pre');
    expect(pre).not.toBeNull();
    expect(pre?.textContent).toContain('flowchart TD');
    // Edge from source to analyze should appear
    expect(pre?.textContent).toContain('-->');
    // No error displayed
    expect(compiled.querySelector('.error')).toBeNull();
  }));

  it('renders role identity and delegated-run lifecycle and usage without native child rows', fakeAsync(() => {
    const fixture = TestBed.createComponent(GraphHubComponent);
    const component = fixture.componentInstance;
    fixture.detectChanges();
    httpMock.expectOne('/api/graph-runs').flush(runsResponse);
    tick();

    const observed: GraphRunDetail = structuredClone(completedRunDetail);
    observed.usage = {
      parent: { input_tokens: 10 },
      delegatedRuns: { input_tokens: 4 },
      total: { input_tokens: 14 },
    };
    observed.concurrencyReductions = ['runtime overlays', 'broker capacity'];
    observed.nodes[0].workspaceMode = 'snapshot';
    observed.nodes[0].workspacePath = '/isolated/source';
    observed.nodes[0].frozenBase = 'base-identity-123456';
    observed.nodes[0].changesetHash = 'changeset-hash-123456';
    observed.nodes[0].role = 'research';
    observed.nodes[0].modelSource = 'runtime saved/default';
    observed.nodes[0].nativeSubagents = 'inherit';
    observed.nodes[0].delegatedRuns = [{
      delegatedRunId: 'delegated-run-source-1',
      runtime: 'codex',
      role: 'code-review',
      workspaceMode: 'snapshot',
      status: 'running',
      verification: 'pending',
      usage: { input_tokens: 4 },
    }];

    component.selectRun(runsResponse.runs[1]);
    fixture.detectChanges();
    httpMock.expectOne(`/api/graph-runs/${encodeURIComponent('my-graph')}/${encodeURIComponent('run-20260101T000000Z-0-abc123')}`).flush(observed);
    tick();
    fixture.detectChanges();

    const compiled: HTMLElement = fixture.nativeElement as HTMLElement;
    expect(compiled.textContent).toContain('delegated runs:');
    expect(compiled.textContent).toContain('running');
    expect(compiled.textContent).toContain('verification=pending');
    expect(compiled.textContent).toContain('roleless');
    expect(compiled.textContent).toContain('research');
    expect(compiled.textContent).toContain('Model source');
    expect(compiled.textContent).toContain('native subagents=inherit');
    expect(compiled.textContent).not.toContain('brokered children:');
    expect(compiled.textContent).not.toContain('native helpers:');
    expect(compiled.textContent).toContain('runtime overlays, broker capacity');
    expect(compiled.textContent).toContain('/isolated/source');
    expect(compiled.querySelector('.dag-pre')?.textContent).toContain('delegated runs (ledger-owned)');
    expect(compiled.querySelector('.dag-pre')?.textContent).toContain('delegated run');
    expect(compiled.querySelector('.dag-pre')?.textContent).not.toContain('native helper');
  }));

  it('shows empty state when no runs exist', fakeAsync(() => {
    const fixture = TestBed.createComponent(GraphHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/graph-runs');
    req.flush({ runs: [] });
    tick();
    fixture.detectChanges();

    const compiled: HTMLElement = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('.empty-state')).not.toBeNull();
    expect(compiled.textContent).toContain('No graph runs found');
  }));

  it('shows error state when the API fails', fakeAsync(() => {
    const fixture = TestBed.createComponent(GraphHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/graph-runs');
    req.flush({ error: 'Failed to read graph-runs directory' }, { status: 500, statusText: 'Server Error' });
    tick();
    fixture.detectChanges();

    const compiled: HTMLElement = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('.error')).not.toBeNull();
  }));
});
