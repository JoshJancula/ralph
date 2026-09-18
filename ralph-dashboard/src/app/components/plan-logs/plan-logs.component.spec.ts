import '../../../angular-test-env';
import { HttpClientTestingModule } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { ActivatedRoute, provideRouter } from '@angular/router';
import { of, throwError } from 'rxjs';
import { vi } from 'vitest';
import { PlanLogsComponent } from './plan-logs.component';
import {
  ApiService,
  PlanRunDetail,
  PlanRunEvidenceEntry,
  PlanRunListItem,
} from '../../services/api.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { NavService } from '../../services/nav.service';

const WORKSPACE = {
  path: '/proj',
  workspaceRoot: '/proj/.ralph-workspace',
  projectRoot: '/proj',
  label: 'p',
  exists: true,
};

function evidenceEntry(overrides: Partial<PlanRunEvidenceEntry> = {}): PlanRunEvidenceEntry {
  const path = overrides.path ?? 'logs/PLAN/plan-usage-summary.json';
  return {
    id: path,
    path,
    label: overrides.label ?? 'Plan usage summary',
    category: overrides.category ?? 'usage-summary',
    kind: 'plan-usage-summary',
    format: overrides.format ?? 'json',
    sizeBytes: 120,
    mtimeMs: 1000,
    target: overrides.target ?? { root: 'logs', path: 'PLAN/plan-usage-summary.json' },
    ...overrides,
  };
}

function listItem(overrides: Partial<PlanRunListItem> = {}): PlanRunListItem {
  return {
    runId: 'run-1',
    planKey: 'PLAN',
    status: 'succeeded',
    startedAt: '2026-01-01T00:00:00Z',
    endedAt: '2026-01-01T00:01:00Z',
    source: 'manifest',
    runtime: 'cursor',
    model: 'composer',
    todosDone: 2,
    todosTotal: 4,
    inputTokens: 10,
    outputTokens: 5,
    elapsedSeconds: 60,
    ...overrides,
  };
}

function detail(overrides: Partial<PlanRunDetail> = {}): PlanRunDetail {
  const evidence: PlanRunEvidenceEntry[] = overrides.files?.evidence ?? [
    evidenceEntry(),
    evidenceEntry({
      path: 'logs/PLAN/runs/run-1/run-manifest.json',
      label: 'Run manifest',
      category: 'run-metadata',
      kind: 'run-manifest',
      target: { root: 'logs', path: 'PLAN/runs/run-1/run-manifest.json' },
    }),
    evidenceEntry({
      path: 'logs/PLAN/plan-runner-output.log',
      label: 'CLI output log',
      category: 'execution-output',
      kind: 'execution-log',
      format: 'log',
      target: { root: 'logs', path: 'PLAN/plan-runner-output.log' },
    }),
  ];
  const summary = evidence
    .filter((e) => e.label === 'Plan usage summary' || e.label === 'Run manifest')
    .map((e) => ({ path: e.path, label: e.label }));
  const raw = evidence.filter((e) => !summary.some((s) => s.path === e.path)).map((e) => e.path);
  return {
    runId: 'run-1',
    planKey: 'PLAN',
    status: 'succeeded',
    source: 'manifest',
    files: overrides.files ?? { evidence, summary, raw },
    timeline: [{ at: '2026-01-01T00:00:30Z', prose: 'invocation' }],
    operatorNext: { label: 'Inspect artifacts', description: 'Review the retained run evidence.', enabled: true },
    discoverReport: '/api/metrics/discover/PLAN',
    resume: {
      resumableTodoCount: 7,
      command: 'ralph run --plan PLAN.md --resume-run run-1',
    },
    usage: {
      runtime: 'cursor',
      model: 'composer',
      todosDone: 2,
      todosTotal: 4,
      inputTokens: 10,
      outputTokens: 5,
      elapsedSeconds: 60,
    },
    ...overrides,
  };
}

describe('PlanLogsComponent', () => {
  function buildComponent(
    paramMap: Record<string, string>,
    queryParamMap: Record<string, string> = {},
    api: Partial<ApiService> = {},
    selected: string | null = null,
    navigate = vi.fn(),
  ) {
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [PlanLogsComponent, HttpClientTestingModule],
      providers: [
        provideRouter([]),
        {
          provide: ActivatedRoute,
          useValue: {
            snapshot: {
              paramMap: { get: (key: string) => paramMap[key] ?? null },
              queryParamMap: { get: (key: string) => queryParamMap[key] ?? null },
            },
          },
        },
        { provide: ApiService, useValue: api },
        { provide: NavService, useValue: { navigate } },
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath: () => selected,
            selectWorkspace: vi.fn(),
            workspaces: () => [],
          },
        },
      ],
    });
    return TestBed.createComponent(PlanLogsComponent);
  }

  function defaultApi(extra: Partial<ApiService> = {}): Partial<ApiService> {
    return {
      fetchWorkspaces: vi.fn(() => of([WORKSPACE])),
      fetchPlanRuns: vi.fn(() => of({ items: [listItem()] })),
      fetchPlanRunDetail: vi.fn(() => of(detail())),
      fetchDiscoverReport: vi.fn(() =>
        of({
          plan_key: 'PLAN',
          path: '/x',
          workspace_root: WORKSPACE.workspaceRoot,
          project_root: WORKSPACE.projectRoot,
          report: {
            schema_version: 1,
            kind: 'discover',
            sequence_patterns: [{ pattern_id: 'repeat-read', count: 3, description: 'reread loop' }],
            aggregate_findings: [{ summary: 'high cache miss' }],
            runtime_differences: [{ summary: 'cursor vs claude tool mix' }],
            high_token_low_cache_invocations: [{ summary: 'invocation 4 burned tokens' }],
          },
        }),
      ),
      fetchListing: vi.fn(() => of({ root: 'artifacts', path: 'PLAN', parent: null, entries: [] })),
      ...extra,
    };
  }

  it('shows empty state when no runs exist', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/proj' }, defaultApi({
      fetchPlanRuns: vi.fn(() => of({ items: [] })),
    }));
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    expect(fixture.nativeElement.textContent).toContain('No runs have been recorded');
    expect(fixture.nativeElement.textContent).toContain('ralph run --plan');
  });

  it('strips .md extension when listing plan runs', async () => {
    const api = defaultApi();
    const fixture = buildComponent({ file: 'plans/PLAN.md' }, { projectRoot: '/proj' }, api);
    await fixture.componentInstance.ngOnInit();

    expect(api.fetchPlanRuns).toHaveBeenCalledWith('PLAN', '/proj/.ralph-workspace');
  });

  it('renders run overview, evidence groups, and timeline', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/proj' }, defaultApi());
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="plan-run-card"]').textContent).toContain('cursor');
    expect(fixture.nativeElement.querySelector('[data-testid="run-headline-status"]').textContent).toContain('succeeded');
    expect(fixture.nativeElement.querySelector('[data-testid="run-manifest-badge"]')).toBeTruthy();
    expect(fixture.nativeElement.querySelector('[data-testid="run-evidence-count"]').textContent).toContain('3 files');
    expect(fixture.nativeElement.querySelector('[data-testid="run-evidence-group-metadata"]')).toBeTruthy();
    expect(fixture.nativeElement.querySelector('[data-testid="run-evidence-group-execution"]')).toBeTruthy();
    expect(fixture.nativeElement.querySelector('[data-testid="run-timeline"]').textContent).toContain('invocation');
    expect(fixture.nativeElement.querySelector('[data-testid="run-raw-files"]')).toBeNull();
  });

  it('lists every evidence file as an open control', async () => {
    const d = detail();
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/proj' }, defaultApi({
      fetchPlanRunDetail: vi.fn(() => of(d)),
    }));
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    const buttons = fixture.nativeElement.querySelectorAll('[data-testid="run-evidence-open"]');
    expect(buttons.length).toBe(d.files.evidence.length);
  });

  it('opens log and json evidence via navigation targets', async () => {
    const navigate = vi.fn();
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/proj' }, defaultApi(), null, navigate);
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    const buttons = fixture.nativeElement.querySelectorAll('[data-testid="run-evidence-open"]');
    (buttons[0] as HTMLButtonElement).click();
    expect(navigate).toHaveBeenCalledWith(
      'logs',
      '',
      'PLAN/plan-usage-summary.json',
      '/proj/.ralph-workspace',
      '/proj',
    );

    (buttons[2] as HTMLButtonElement).click();
    expect(navigate).toHaveBeenCalledWith(
      'logs',
      '',
      'PLAN/plan-runner-output.log',
      '/proj/.ralph-workspace',
      '/proj',
    );
  });

  it('renders legacy compatibility without treating the run as incomplete', async () => {
    const legacyEvidence = [
      evidenceEntry({
        path: 'logs/LEGACY/plan-usage-summary.json',
        target: { root: 'logs', path: 'LEGACY/plan-usage-summary.json' },
      }),
      evidenceEntry({
        path: 'logs/LEGACY/output.log',
        label: 'CLI output log',
        category: 'execution-output',
        format: 'log',
        target: { root: 'logs', path: 'LEGACY/output.log' },
      }),
    ];
    const fixture = buildComponent({ file: 'LEGACY.md' }, { projectRoot: '/proj' }, defaultApi({
      fetchPlanRuns: vi.fn(() => of({ items: [listItem({ runId: 'legacy-run-1', source: 'legacy', planKey: 'LEGACY' })] })),
      fetchPlanRunDetail: vi.fn(() => of(detail({
        runId: 'legacy-run-1',
        planKey: 'LEGACY',
        source: 'legacy',
        files: {
          evidence: legacyEvidence,
          summary: [{ path: legacyEvidence[0].path, label: legacyEvidence[0].label }],
          raw: [legacyEvidence[1].path],
        },
      }))),
    }));
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="run-legacy-badge"]')).toBeTruthy();
    expect(fixture.nativeElement.textContent).toContain('Legacy compatibility');
    expect(fixture.nativeElement.textContent).not.toContain('degraded');
    expect(fixture.nativeElement.querySelector('[data-testid="run-evidence-group-execution"]')).toBeTruthy();
  });

  it('loads a deep-linked run from plan-runs/:runId', async () => {
    const api = defaultApi();
    const fixture = buildComponent({ runId: 'run-1' }, { projectRoot: '/proj' }, api);
    await fixture.componentInstance.ngOnInit();

    expect(api.fetchPlanRunDetail).toHaveBeenCalledWith('run-1', '/proj/.ralph-workspace');
    expect(api.fetchPlanRuns).toHaveBeenCalledWith('PLAN', '/proj/.ralph-workspace');
  });

  it('does not fall back to the first workspace when projectRoot is missing', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, {}, {
      fetchWorkspaces: vi.fn(() => of([
        { path: '/global', workspaceRoot: '/global/.ralph-workspace', projectRoot: '/global', label: 'g', exists: true },
        WORKSPACE,
      ])),
      fetchPlanRuns: vi.fn(),
    });
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    expect(fixture.componentInstance.error()).toBeInstanceOf(Error);
    expect(fixture.componentInstance.loading()).toBe(false);
  });

  it('shows error when workspace lookup fails', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/missing' }, {
      fetchWorkspaces: vi.fn(() => of([WORKSPACE])),
    });
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    expect(String((fixture.componentInstance.error() as Error).message)).toContain('plan workspace is unavailable');
  });

  it('shows error when listing fails', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/proj' }, defaultApi({
      fetchPlanRuns: vi.fn(() => throwError(() => new Error('fail'))),
    }));
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    expect(String((fixture.componentInstance.error() as Error).message)).toContain('fail');
  });

  it('selects the matching workspace when the selector is out of sync', async () => {
    const selectWorkspace = vi.fn();
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [PlanLogsComponent, HttpClientTestingModule],
      providers: [
        provideRouter([]),
        {
          provide: ActivatedRoute,
          useValue: {
            snapshot: {
              paramMap: { get: (key: string) => (key === 'file' ? 'PLAN.md' : null) },
              queryParamMap: { get: (key: string) => (key === 'projectRoot' ? '/proj' : null) },
            },
          },
        },
        { provide: ApiService, useValue: defaultApi() },
        { provide: NavService, useValue: { navigate: vi.fn() } },
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath: () => '/other',
            selectWorkspace,
            workspaces: () => [],
          },
        },
      ],
    });
    const fixture = TestBed.createComponent(PlanLogsComponent);
    await fixture.componentInstance.ngOnInit();
    expect(selectWorkspace).toHaveBeenCalledWith('/proj');
  });

  it('shows actionable empty evidence state', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/proj' }, defaultApi({
      fetchPlanRunDetail: vi.fn(() => of(detail({ files: { evidence: [], summary: [], raw: [] } }))),
    }));
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="run-evidence-empty"]').textContent).toContain('No evidence files');
  });
});
