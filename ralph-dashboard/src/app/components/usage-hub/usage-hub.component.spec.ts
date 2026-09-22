import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ComponentFixture, signal } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';

import type {
  MetricsBreakdownResponse,
  MetricsDetailResponse,
  MetricsInsightsSummary,
  SavingsReport,
  WorkspaceRegistry,
} from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { UsageHubComponent } from './usage-hub.component';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';

const mockInsights: MetricsInsightsSummary = {
  date_scope: {
    from: '2026-04-16',
    to: '2026-04-17',
    label: '2026-04-16 to 2026-04-17',
    run_count: 2,
  },
  units: { tokens: 'tokens', elapsed: 'seconds', tool_calls: 'calls' },
  headline: {
    total_tokens: 530,
    input_tokens: 180,
    output_tokens: 100,
    cache_read_input_tokens: 250,
    cache_hit_ratio: 0.58,
    elapsed_seconds: 21,
    tool_calls_total: 12,
    run_count: 2,
  },
  trend: {
    direction: 'up',
    recent_tokens: 330,
    prior_tokens: 200,
    delta_tokens: 130,
    delta_percent: 65,
    recent_run_count: 1,
    prior_run_count: 1,
  },
  drivers: [
    {
      kind: 'runtime',
      label: 'codex',
      exact_value: 'codex',
      total_tokens: 420,
      share_percent: 79.2,
      runs: 1,
    },
    {
      kind: 'model',
      label: 'GPT-5 family',
      exact_value: 'gpt-5.4-mini',
      total_tokens: 420,
      share_percent: 79.2,
      runs: 1,
    },
  ],
  anomalies: [
    {
      code: 'token-spike',
      severity: 'warn',
      message: 'Recent runs used 65% more tokens than the prior half of the date scope.',
    },
  ],
  drilldowns: [
    { id: 'runtime', label: 'Runtime breakdown', target: 'breakdown' },
    { id: 'model', label: 'Model breakdown', target: 'breakdown' },
    { id: 'runs', label: 'Run table', target: 'breakdown' },
  ],
  filter_options: {
    runtimes: ['claude', 'codex'],
    models: [
      { label: 'Claude Sonnet', exact_value: 'sonnet' },
      { label: 'GPT-5 family', exact_value: 'gpt-5.4-mini' },
    ],
  },
};

const mockBreakdown: MetricsBreakdownResponse = {
  date_scope: {
    from: '2026-04-16',
    to: '2026-04-17',
    label: '2026-04-16 to 2026-04-17',
  },
  units: { tokens: 'tokens', elapsed: 'seconds', tool_calls: 'calls' },
  filtered_run_count: 2,
  total_run_count: 2,
  runtime_rows: [
    {
      runtime: 'codex',
      model_count: 1,
      runs: 1,
      invocations: 2,
      input_tokens: 120,
      output_tokens: 80,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 220,
      total_tokens: 420,
      tool_calls_total: 8,
      cache_hit_ratio: 0.6471,
      max_turn_total_tokens: 900,
      elapsed_seconds: 10,
    },
  ],
  model_rows: [
    {
      runtime: 'codex',
      model: 'gpt-5.4-mini',
      model_label: 'GPT-5 family',
      model_exact: 'gpt-5.4-mini',
      runs: 1,
      invocations: 2,
      input_tokens: 120,
      output_tokens: 80,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 220,
      total_tokens: 420,
      tool_calls_total: 8,
      cache_hit_ratio: 0.6471,
      max_turn_total_tokens: 900,
      elapsed_seconds: 10,
    },
  ],
  run_rows: [
    {
      kind: 'plan',
      path: '/logs/plan-1/plan-usage-summary.json',
      plan_key: 'plan-1',
      workspace_root: '/ws',
      runtime: 'codex',
      model_label: 'GPT-5 family',
      model_exact: 'gpt-5.4-mini',
      model_count: 2,
      models: [
        {
          runtime: 'codex',
          model: 'gpt-5.4-mini',
          model_label: 'GPT-5 family',
          model_exact: 'gpt-5.4-mini',
          invocations: 1,
          input_tokens: 100,
          output_tokens: 60,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 200,
          total_tokens: 360,
          tool_calls_total: 6,
          elapsed_seconds: 7,
        },
        {
          runtime: 'codex',
          model: 'claude-haiku-4-5',
          model_label: 'Claude Haiku',
          model_exact: 'claude-haiku-4-5',
          invocations: 1,
          input_tokens: 20,
          output_tokens: 20,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 20,
          total_tokens: 60,
          tool_calls_total: 2,
          elapsed_seconds: 3,
        },
      ],
      started_at: '2026-04-16T09:00:00.000Z',
      input_tokens: 120,
      output_tokens: 80,
      cache_read_input_tokens: 220,
      total_tokens: 420,
      tool_calls_total: 8,
      cache_hit_ratio: 0.6471,
      elapsed_seconds: 10,
    },
  ],
  page: { offset: 0, limit: 25, total: 1 },
  sort: { by: 'total_tokens', dir: 'desc' },
};

const mockDetail: MetricsDetailResponse = {
  plan_key: 'plan-1',
  kind: 'plan',
  item: {
    path: '/logs/plan-1/plan-usage-summary.json',
    plan_key: 'plan-1',
    artifact_ns: 'plan-1',
    workspace_root: '/ws',
    project_root: '/proj',
    runtime: 'codex',
    model: 'gpt-5.4-mini',
    started_at: '2026-04-16T09:00:00.000Z',
    elapsed_seconds: 10,
    input_tokens: 120,
    output_tokens: 80,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 220,
    max_turn_total_tokens: 900,
    cache_hit_ratio: 0.6471,
    tool_calls_total: 8,
    model_breakdown: [
      {
        runtime: 'codex',
        model: 'gpt-5.4-mini',
        invocations: 1,
        elapsed_seconds: 7,
        input_tokens: 100,
        output_tokens: 60,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 200,
        max_turn_total_tokens: 900,
        cache_hit_ratio: 0.66,
        tool_calls_total: 6,
      },
      {
        runtime: 'codex',
        model: 'claude-haiku-4-5',
        invocations: 1,
        elapsed_seconds: 3,
        input_tokens: 20,
        output_tokens: 20,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 20,
        max_turn_total_tokens: 300,
        cache_hit_ratio: 0.33,
        tool_calls_total: 2,
      },
    ],
  },
  related: [],
};

const mockSavingsReport: SavingsReport = {
  schema_version: 2,
  kind: 'ralph_benchmark_report',
  run_count: 2,
  date_range: {
    started_at: '2026-05-01T00:00:00.000Z',
    ended_at: '2026-05-02T00:00:00.000Z',
  },
  saved_bytes: 4096,
  saved_tokens: 1024,
  savings_percent: 0.4,
  session_usage: {
    input_tokens: 10000,
    output_tokens: 2000,
    cache_creation_input_tokens: 500,
    cache_read_input_tokens: 1500,
    prompt_bytes: 12000,
    tool_calls_total: 42,
  },
  tool_output_counterfactual: {
    hypothetical_without_ralph_bytes: 8192,
    actual_with_ralph_bytes: 4096,
    net_savings_bytes: 4096,
    hypothetical_without_ralph_tokens: 2048,
    actual_with_ralph_tokens: 1024,
    net_savings_tokens: 1024,
    net_savings_percent: 50,
    compaction_measured_not_applied_bytes: 0,
    compaction_measured_not_applied_tokens: 0,
  },
  per_path: {},
  cache: {
    cache_read_tokens: 200,
    cache_hit_ratio: 0.65,
  },
  could_have_saved: {
    compaction_measured_not_applied_bytes: 0,
  },
};

const mockAmbientUsage = {
  enabled: true,
  scope: 'machine_local' as const,
  date_scope: { from: null, to: null, label: 'All available history' },
  providers: [
    {
      id: 'claude_code' as const,
      label: 'Claude',
      status: 'available' as const,
      rate_limits: [
        {
          id: 'five_hour',
          label: '5h',
          used_percent: 12,
          resets_at: '2026-09-18T08:00:00.000Z',
          resets_in_seconds: 3600,
        },
        {
          id: 'seven_day',
          label: 'Weekly',
          used_percent: 79,
          resets_at: '2026-09-20T08:00:00.000Z',
          resets_in_seconds: 172800,
        },
      ],
      tokens: {
        input_tokens: 100,
        output_tokens: 50,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0,
        total_tokens: 150,
        session_count: 1,
      },
      model_breakdown: [],
      updated_at: '2026-09-18T00:00:00.000Z',
    },
    {
      id: 'codex' as const,
      label: 'Codex',
      status: 'available' as const,
      rate_limits: [
        {
          id: 'secondary',
          label: 'Weekly',
          used_percent: 77,
          resets_at: '2026-09-22T08:00:00.000Z',
          resets_in_seconds: 345600,
        },
      ],
      tokens: {
        input_tokens: 0,
        output_tokens: 0,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0,
        total_tokens: 0,
        session_count: 0,
      },
      model_breakdown: [],
      updated_at: '2026-09-18T00:00:00.000Z',
    },
  ],
};

const noJevUsage = {
  enabled: false,
  calls: 0,
  calls_measured: 0,
  calls_unavailable: 0,
  input_tokens: 0,
  output_tokens: 0,
  estimated_usd: 0,
  by_question_set: [],
};

function flushPendingSavings(httpMock: HttpTestingController): void {
  for (const req of httpMock.match((r) => r.url.startsWith('/api/benchmarks'))) {
    req.flush(mockSavingsReport);
  }
  // Jev is optional; unless a test flushes its own payload, report none.
  for (const req of httpMock.match((r) => r.url.startsWith('/api/metrics/jev-usage'))) {
    req.flush(noJevUsage);
  }
}

function expectInsightsSummary(httpMock: HttpTestingController) {
  return httpMock.expectOne((req) => req.url.startsWith('/api/metrics/insights-summary'));
}

function expectBreakdown(httpMock: HttpTestingController) {
  return httpMock.expectOne((req) => req.url.startsWith('/api/metrics/breakdown'));
}

function mountUsageHub(fixture: ComponentFixture<UsageHubComponent>): void {
  fixture.componentRef.setInput('paneActive', true);
  fixture.detectChanges();
}

describe('UsageHubComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [UsageHubComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
      providers: [
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath: signal<string | null>(null),
            workspaces: signal<WorkspaceRegistry[]>([]),
          },
        },
        {
          provide: NavService,
          useValue: { navigate: vi.fn() },
        },
      ],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('loads insights summary and breakdown on independent requests', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);

    const summaryReq = expectInsightsSummary(httpMock);
    const breakdownReq = expectBreakdown(httpMock);
    expect(summaryReq.request.url).toContain('/api/metrics/insights-summary');
    expect(breakdownReq.request.url).toContain('/api/metrics/breakdown');
    expect(summaryReq.request.url).not.toContain('/api/metrics/breakdown');
    expect(breakdownReq.request.url).not.toContain('/api/metrics/insights-summary');

    const component = fixture.componentInstance;
    expect(component.summaryLoading).toBe(true);
    expect(component.breakdownLoading).toBe(true);

    summaryReq.flush(mockInsights);
    fixture.detectChanges();
    expect(component.summaryLoading).toBe(false);
    expect(component.insights?.headline.total_tokens).toBe(530);
    expect(component.breakdownLoading).toBe(true);

    breakdownReq.flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    expect(component.breakdownLoading).toBe(false);
    expect(component.breakdown?.runtime_rows).toHaveLength(1);
    expect(fixture.nativeElement.querySelector('[data-testid="insights-summary"]')).toBeTruthy();
    expect(fixture.nativeElement.textContent).toContain('What changed');
    expect(fixture.nativeElement.textContent).toContain('GPT-5 family');
  });

  it('shows a separate Jev panel only when Jev usage was recorded', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);

    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    for (const req of httpMock.match((r) => r.url.startsWith('/api/benchmarks'))) {
      req.flush(mockSavingsReport);
    }
    const jevReq = httpMock.expectOne((r) => r.url.startsWith('/api/metrics/jev-usage'));
    jevReq.flush({
      enabled: true,
      calls: 3,
      calls_measured: 2,
      calls_unavailable: 1,
      input_tokens: 592,
      output_tokens: 40,
      estimated_usd: 0.000025,
      by_question_set: [
        { question_set_id: 'graph.router-confidence', calls: 3, input_tokens: 592, output_tokens: 40 },
      ],
    });
    fixture.detectChanges();

    const panel = fixture.nativeElement.querySelector('[data-testid="insights-jev-usage"]');
    expect(panel).toBeTruthy();
    expect(panel.textContent).toContain('graph.router-confidence');
    expect(panel.textContent).toContain('Separate from runtime token totals');
    expect(fixture.nativeElement.querySelector('[data-testid="insights-jev-unavailable"]')).toBeTruthy();
  });

  it('hides the Jev panel when no Jev usage was recorded', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);

    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="insights-jev-usage"]')).toBeNull();
  });

  it('does not block summary render while breakdown is still loading', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);

    expectInsightsSummary(httpMock).flush(mockInsights);
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="insights-summary"]')).toBeTruthy();
    expect(fixture.nativeElement.querySelector('[data-testid="insights-breakdown-loading"]')).toBeTruthy();

    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="insights-breakdown-loading"]')).toBeNull();
  });

  it('keeps the answer visible while a refresh is in flight', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    fixture.componentInstance.refresh();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="insights-summary"]')).toBeTruthy();
    expect(fixture.nativeElement.querySelector('[data-testid="insights-busy"]')).toBeTruthy();
    expect(fixture.nativeElement.querySelector('[data-testid="route-loading-skeleton"]')).toBeNull();
    expect(fixture.nativeElement.textContent).not.toContain('Back to Plans');

    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="insights-busy"]')).toBeNull();
  });

  it('shows an empty state instead of zero metric cards when there are no runs', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    const emptyInsights: MetricsInsightsSummary = {
      ...mockInsights,
      date_scope: { ...mockInsights.date_scope, run_count: 0 },
      headline: { ...mockInsights.headline, run_count: 0, total_tokens: 0 },
      drivers: [],
      anomalies: [],
    };
    expectInsightsSummary(httpMock).flush(emptyInsights);
    expectBreakdown(httpMock).flush({
      ...mockBreakdown,
      filtered_run_count: 0,
      total_run_count: 0,
      runtime_rows: [],
      model_rows: [],
      run_rows: [],
      page: { offset: 0, limit: 25, total: 0 },
    });
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="insights-empty"]')).toBeTruthy();
    expect(fixture.nativeElement.querySelector('[data-testid="insights-summary"]')).toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="insights-breakdown"]')).toBeNull();
    expect(fixture.nativeElement.textContent).toContain('No usage in this scope');
  });

  it('renders compact token totals on the answer panel', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    const huge = {
      ...mockInsights,
      headline: { ...mockInsights.headline, total_tokens: 13_814_243_702 },
    };
    expectInsightsSummary(httpMock).flush(huge);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent as string;
    expect(text).toContain('13.8B');
    expect(text).not.toContain('13,814,243,702');
    expect(fixture.nativeElement.querySelector('[data-testid="insights-trend-chart"]')).toBeTruthy();
  });

  it('flags runs that used more than one model in the run table', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const badge = fixture.nativeElement.querySelector(
      '[data-testid="models-more-plan-1"]',
    ) as HTMLElement;
    expect(badge).toBeTruthy();
    expect(badge.textContent?.trim()).toBe('+1 more');

    const modelCell = badge.closest('[data-label="Model"]') as HTMLElement;
    expect(modelCell.getAttribute('title')).toContain('claude-haiku-4-5');
  });

  it('opens the detail modal when the run row itself is clicked', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const row = fixture.nativeElement.querySelector('[data-testid="run-row-plan-1"]') as HTMLElement;
    expect(row).toBeTruthy();
    row.click();
    fixture.detectChanges();

    // expectOne also proves the row click did not fire a duplicate request.
    httpMock.expectOne((req) => req.url.includes('/api/metrics/detail/plan-1')).flush(mockDetail);
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="insights-detail-modal"]')).toBeTruthy();
    expect(fixture.nativeElement.querySelector('[data-testid="insights-detail-models"]')).toBeTruthy();
  });

  it('does not double-request detail when the Inspect button inside a row is clicked', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const inspect = fixture.nativeElement.querySelector('[data-testid="detail-plan-1"]') as HTMLButtonElement;
    inspect.click();
    fixture.detectChanges();

    httpMock.expectOne((req) => req.url.includes('/api/metrics/detail/plan-1')).flush(mockDetail);
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="insights-detail-modal"]')).toBeTruthy();
  });

  it('loads optional detail only when Inspect is clicked', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    httpMock.expectNone((req) => req.url.includes('/api/metrics/detail/'));

    const inspect = fixture.nativeElement.querySelector('[data-testid="detail-plan-1"]') as HTMLButtonElement;
    expect(inspect).toBeTruthy();
    inspect.click();
    fixture.detectChanges();

    const detailReq = httpMock.expectOne((req) => req.url.includes('/api/metrics/detail/plan-1'));
    detailReq.flush(mockDetail);
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="insights-detail-modal"]')).toBeTruthy();
    expect(fixture.nativeElement.querySelector('[data-testid="insights-detail"]')).toBeTruthy();
    expect(fixture.nativeElement.textContent).toContain('plan-1');

    const detailModels = fixture.nativeElement.querySelector(
      '[data-testid="insights-detail-models"]',
    ) as HTMLElement;
    expect(detailModels).toBeTruthy();
    expect(detailModels.textContent).toContain('gpt-5.4-mini');
    expect(detailModels.textContent).toContain('claude-haiku-4-5');
    expect(detailModels.querySelectorAll('.usage-row:not(.usage-header)').length).toBe(2);
    const planLink = fixture.nativeElement.querySelector('[data-testid="insights-detail-plan-link"]') as HTMLAnchorElement;
    expect(planLink).toBeTruthy();
    expect(planLink.getAttribute('href')).toContain('/plan-detail/plan-1');

    planLink.click();
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="insights-detail-modal"]')).toBeNull();

  });

  it('scopes breakdown requests to selected project and filters', () => {
    const workspaceSignal = signal<string | null>('/proj');
    const workspacesSignal = signal<WorkspaceRegistry[]>([
      {
        path: '/proj',
        label: 'Proj',
        workspaceRoot: '/proj/.ralph-workspace',
        projectRoot: '/proj',
        exists: true,
      },
    ]);
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [UsageHubComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
      providers: [
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath: workspaceSignal,
            workspaces: workspacesSignal,
          },
        },
        { provide: NavService, useValue: { navigate: vi.fn() } },
      ],
    });
    httpMock = TestBed.inject(HttpTestingController);

    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);

    const summaryReq = expectInsightsSummary(httpMock);
    const breakdownReq = expectBreakdown(httpMock);
    expect(summaryReq.request.params.get('workspaceRoot')).toBe('/proj/.ralph-workspace');
    expect(breakdownReq.request.params.get('workspaceRoot')).toBe('/proj/.ralph-workspace');

    summaryReq.flush(mockInsights);
    breakdownReq.flush(mockBreakdown);
    flushPendingSavings(httpMock);

    fixture.componentInstance.setFilterRuntime('codex');
    fixture.detectChanges();

    const filteredSummary = expectInsightsSummary(httpMock);
    const filteredBreakdown = expectBreakdown(httpMock);
    expect(filteredSummary.request.params.get('runtime')).toBe('codex');
    expect(filteredBreakdown.request.params.get('runtime')).toBe('codex');
    filteredSummary.flush(mockInsights);
    filteredBreakdown.flush(mockBreakdown);
    flushPendingSavings(httpMock);
  });

  it('exposes friendly model label with inspectable exact value', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent as string;
    expect(text).toContain('GPT-5 family');
    expect(text).toContain('gpt-5.4-mini');
  });

  it('keeps Refine scope as a compact always-visible filter bar', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const filters = fixture.nativeElement.querySelector('[data-testid="insights-filters"]') as HTMLElement;
    expect(filters.tagName).toBe('SECTION');
    expect(filters.querySelector('details')).toBeNull();
    expect(filters.textContent).toContain('Refine scope');
    expect(filters.querySelector('.filter-select')).toBeTruthy();
  });

  it('puts breakdown tables in expansion panels with runtime open by default', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const runtime = fixture.nativeElement.querySelector('[data-testid="insights-panel-runtime"]') as HTMLDetailsElement;
    const model = fixture.nativeElement.querySelector('[data-testid="insights-panel-model"]') as HTMLDetailsElement;
    const runs = fixture.nativeElement.querySelector('[data-testid="insights-panel-runs"]') as HTMLDetailsElement;
    expect(runtime.open).toBe(true);
    expect(model.open).toBe(false);
    expect(runs.open).toBe(false);
  });

  it('opens the matching breakdown panel when a drilldown is clicked', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const modelPanel = fixture.nativeElement.querySelector('[data-testid="insights-panel-model"]') as HTMLDetailsElement;
    expect(modelPanel.open).toBe(false);
    fixture.componentInstance.openDrilldown('model');
    fixture.detectChanges();
    expect(modelPanel.open).toBe(true);
    expect(fixture.componentInstance.activeDrill).toBe('model');
  });

  describe('formatting and filter helpers', () => {
    let component: UsageHubComponent;

    beforeEach(() => {
      const fixture = TestBed.createComponent(UsageHubComponent);
      component = fixture.componentInstance;
      component.insights = mockInsights;
      component.breakdown = mockBreakdown;
    });

    it('maps friendly model labels and truncates long ids', () => {
      expect(component.friendlyModel('')).toBe('Unspecified model');
      expect(component.friendlyModel('claude-3-opus-latest')).toBe('Claude Opus');
      expect(component.friendlyModel('claude-sonnet-4')).toBe('Claude Sonnet');
      expect(component.friendlyModel('gpt-5-preview')).toBe('GPT-5 family');
      expect(component.friendlyModel('gpt-4o-mini')).toBe('GPT-4o');
      expect(component.friendlyModel('very-long-custom-model-id-abcdef')).toMatch(/\.\.\.$/);
    });

    it('describes trend direction in plain language', () => {
      expect(
        component.trendSentence({
          ...mockInsights,
          trend: { ...mockInsights.trend, direction: 'unknown' },
        }),
      ).toContain('Not enough dated runs');
      expect(
        component.trendSentence({
          ...mockInsights,
          trend: { ...mockInsights.trend, direction: 'flat', delta_percent: 0, delta_tokens: 0 },
        }),
      ).toContain('roughly flat');
      expect(
        component.trendSentence({
          ...mockInsights,
          trend: { ...mockInsights.trend, direction: 'up', delta_percent: 12, delta_tokens: 100 },
        }),
      ).toContain('up 12%');
      expect(
        component.trendSentence({
          ...mockInsights,
          trend: { ...mockInsights.trend, direction: 'down', delta_percent: null, delta_tokens: -50 },
        }),
      ).toContain('down');
    });

    it('formats numbers, compact values, and percentages', () => {
      expect(component.formatNumber(Number.NaN)).toBe('0');
      expect(component.formatCompact(Number.NaN)).toBe('0');
      expect(component.formatCompact(-1500)).toBe('-1.5K');
      expect(component.formatCompact(1500)).toBe('1.5K');
      expect(component.formatCompact(2_500_000)).toBe('2.5M');
      expect(component.formatCompact(3_000_000_000)).toBe('3B');
      expect(component.formatCompact(4e12)).toBe('4T');
      expect(component.formatCompact(42)).toBe('42');
      expect(component.formatPercent(0)).toBe('--');
      expect(component.formatPercent(Number.NaN)).toBe('--');
      expect(component.formatPercent(0.123)).toBe('12.3%');
      expect(component.formatSeconds(90)).toBe('1m 30s');
    });

    it('computes run model counts and drilldown metadata', () => {
      const row = mockBreakdown.run_rows[0];
      expect(component.runModelCount(row)).toBe(2);
      expect(component.extraModelCount(row)).toBe(1);
      expect(component.runModelsTitle(row)).toContain('gpt-5.4-mini');
      expect(component.runModelsTitle({ ...row, models: [] })).toBe(row.model_exact);
      expect(component.runModelCount({ ...row, model_count: undefined, models: undefined })).toBe(1);
      expect(component.trendShare(mockInsights.trend.recent_tokens)).toBeGreaterThan(0);
      expect(component.trendShare(Number.NaN)).toBe(0);
      component.insights = null;
      expect(component.trendShare(10)).toBe(1000);
    });

    it('reports paging and filter state', () => {
      expect(component.pageLabel).toMatch(/1-/);
      expect(component.hasNextPage).toBe(false);
      component.filterKind = 'plan';
      expect(component.hasActiveFilters).toBe(true);
      component.filterKind = 'all';
      expect(component.hasActiveFilters).toBe(false);
      component.breakdown = null;
      expect(component.pageLabel).toBe('0 / 0');
      expect(component.hasNextPage).toBe(false);
      component.breakdown = {
        ...mockBreakdown,
        page: { offset: 0, limit: 25, total: 0 },
      };
      expect(component.pageLabel).toBe('0 / 0');
      component.breakdown = {
        ...mockBreakdown,
        page: { offset: 0, limit: 25, total: 40 },
      };
      expect(component.hasNextPage).toBe(true);
      expect(component.pageLabel).toBe('1-25 / 40');
      expect(component.hasUsageData).toBe(true);
      component.insights = { ...mockInsights, headline: { ...mockInsights.headline, run_count: 0 } };
      expect(component.hasUsageData).toBe(false);
    });

    it('ignores invalid drilldown ids', () => {
      component.openDrilldown('not-a-section');
      expect(component.activeDrill).toBeNull();
    });

    it('aggregates detail model rows with caching', () => {
      const item = {
        path: '/logs/plan-1/plan-usage-summary.json',
        plan_key: 'plan-1',
        runtime: 'codex',
        model: 'gpt-5.4-mini',
        model_breakdown: mockBreakdown.run_rows[0].models,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        total_tokens: 0,
        tool_calls_total: 0,
        elapsed_seconds: 0,
      };
      const first = component.detailModelRows(item);
      const second = component.detailModelRows(item);
      expect(first?.length).toBe(2);
      expect(second).toBe(first);
      expect(component.detailModelRows(null)).toBeNull();
      expect(
        component.detailModelRows({
          ...item,
          path: '/other',
          model_breakdown: [
            {
              runtime: '',
              model: '',
              invocations: 0,
              input_tokens: 1,
              output_tokens: 2,
              cache_creation_input_tokens: undefined,
              cache_read_input_tokens: undefined,
              total_tokens: 3,
              tool_calls_total: undefined,
              elapsed_seconds: undefined,
            } as never,
          ],
          runtime: '',
          model: '',
        })?.[0].runtime,
      ).toBe('(unspecified)');
    });

    it('sorts, pages, clears filters, and closes detail on escape', () => {
      vi.spyOn(component as unknown as { loadBreakdown: () => void }, 'loadBreakdown').mockImplementation(() => {});
      vi.spyOn(component as unknown as { reloadFiltered: () => void }, 'reloadFiltered').mockImplementation(() => {});

      component.sortRuns('total_tokens');
      expect(component.sortDir).toBe('asc');
      component.sortRuns('plan_key');
      expect(component.sortBy).toBe('plan_key');
      expect(component.sortDir).toBe('asc');
      component.sortRuns('elapsed_seconds');
      expect(component.sortDir).toBe('desc');

      component.breakdown = { ...mockBreakdown, page: { offset: 0, limit: 25, total: 40 } };
      component.pageOffset = 0;
      component.nextPage();
      expect(component.pageOffset).toBe(25);
      component.breakdown = { ...mockBreakdown, page: { offset: 25, limit: 25, total: 40 } };
      component.nextPage();
      expect(component.pageOffset).toBe(25);
      component.prevPage();
      expect(component.pageOffset).toBe(0);

      component.filterKind = 'orchestration';
      component.filterRuntime = 'codex';
      component.filterModel = 'x';
      component.filterDateFrom = '2026-01-01';
      component.filterDateTo = '2026-01-02';
      expect(component.hasActiveFilters).toBe(true);
      component.clearFilters();
      expect(component.filterKind).toBe('all');
      expect(component.filterRuntime).toBe('all');
      expect(component.filterDateFrom).toBe('');

      component.detail = mockDetail;
      component.closeDetailOnEscape();
      expect(component.detail).toBeNull();
    });

    it('normalizes filter setters and skips inactive pane refreshes', () => {
      const fixture = TestBed.createComponent(UsageHubComponent);
      const hub = fixture.componentInstance;
      vi.spyOn(hub as unknown as { reloadFiltered: () => void }, 'reloadFiltered').mockImplementation(() => {});
      hub.setFilterKind('plan');
      expect(hub.filterKind).toBe('plan');
      hub.setFilterKind('orchestration');
      expect(hub.filterKind).toBe('orchestration');
      hub.setFilterKind('nope');
      expect(hub.filterKind).toBe('all');
      hub.setFilterRuntime('  ');
      expect(hub.filterRuntime).toBe('all');
      hub.setFilterModel('  gpt  ');
      expect(hub.filterModel).toBe('gpt');
      hub.setFilterDateFrom(' 2026-01-01 ');
      hub.setFilterDateTo(' ');
      expect(hub.filterDateFrom).toBe('2026-01-01');
      expect(hub.filterDateTo).toBe('');

      fixture.componentRef.setInput('paneActive', false);
      fixture.detectChanges();
      expect(httpMock.match((r) => r.url.startsWith('/api/metrics')).length).toBe(0);
    });
  });

  it('reloads breakdown and savings when filters change', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    fixture.componentInstance.setFilterRuntime('codex');
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    expect(fixture.componentInstance.filterRuntime).toBe('codex');
  });

  it('downloads breakdown csv and ignores missing breakdown', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const createObjectURL = vi.fn(() => 'blob:csv');
    const revokeObjectURL = vi.fn();
    const click = vi.fn();
    vi.stubGlobal('URL', { createObjectURL, revokeObjectURL });
    const originalCreate = document.createElement.bind(document);
    vi.spyOn(document, 'createElement').mockImplementation((tag: string) => {
      const el = originalCreate(tag);
      if (tag === 'a') {
        Object.defineProperty(el, 'click', { value: click });
      }
      return el;
    });

    fixture.componentInstance.downloadBreakdownCsv();
    expect(createObjectURL).toHaveBeenCalled();
    expect(click).toHaveBeenCalled();
    expect(revokeObjectURL).toHaveBeenCalled();

    fixture.componentInstance.breakdown = null;
    createObjectURL.mockClear();
    fixture.componentInstance.downloadBreakdownCsv();
    expect(createObjectURL).not.toHaveBeenCalled();
    vi.unstubAllGlobals();
  });

  it('surfaces detail errors and closes the modal', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    fixture.componentInstance.loadDetail('plan-1');
    const detailReq = httpMock.expectOne((r) => r.url.startsWith('/api/metrics/detail'));
    detailReq.flush(
      { code: 'INTERNAL', message: 'detail failed', title: 'Detail failed', explanation: 'x', recoverable: true },
      { status: 500, statusText: 'Error' },
    );
    fixture.detectChanges();
    expect(fixture.componentInstance.detailError).toBeTruthy();
    expect(fixture.componentInstance.detailLoading).toBe(false);

    fixture.componentInstance.closeDetail();
    expect(fixture.componentInstance.detailError).toBeNull();
  });

  it('surfaces breakdown errors from the API', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(
      { code: 'INTERNAL', message: 'breakdown failed', title: 'Breakdown failed', explanation: 'x', recoverable: true },
      { status: 500, statusText: 'Error' },
    );
    flushPendingSavings(httpMock);
    fixture.detectChanges();
    expect(fixture.componentInstance.breakdownError).toBeTruthy();
  });

  it('surfaces summary errors from the API', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(
      { code: 'INTERNAL', message: 'boom', title: 'Insights failed', explanation: 'x', recoverable: true },
      { status: 500, statusText: 'Error' },
    );
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();
    expect(fixture.componentInstance.summaryError).toBeTruthy();
    expect(fixture.nativeElement.querySelector('[data-testid="insights-summary-error"]')).toBeTruthy();
  });

  it('surfaces savings errors from the API', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    for (const req of httpMock.match((r) => r.url.startsWith('/api/benchmarks'))) {
      req.flush(
        { code: 'INTERNAL', message: 'savings failed', title: 'Savings failed', explanation: 'x', recoverable: true },
        { status: 500, statusText: 'Error' },
      );
    }
    flushPendingSavings(httpMock);
    fixture.detectChanges();
    expect(fixture.componentInstance.savingsError).toBeTruthy();
  });

  it('ignores escape when detail is closed and skips stale detail responses', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const hub = fixture.componentInstance;
    hub.closeDetailOnEscape();
    expect(hub.detail).toBeNull();

    hub.loadDetail('plan-1');
    hub.loadDetail('plan-2');
    const detailReqs = httpMock.match((r) => r.url.startsWith('/api/metrics/detail'));
    expect(detailReqs.length).toBeGreaterThanOrEqual(1);
    const live = detailReqs.filter((r) => !r.cancelled);
    expect(live.length).toBe(1);
    live[0].flush({ ...mockDetail, plan_key: 'plan-2' });
    fixture.detectChanges();
    expect(hub.detail?.plan_key).toBe('plan-2');
  });

  it('ignores abort and stale errors for summary/breakdown/detail', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    mountUsageHub(fixture);
    const hub = fixture.componentInstance;
    const lifecycle = hub['requestLifecycle'];
    const isCurrent = vi.spyOn(lifecycle, 'isCurrent').mockReturnValue(false);

    expectInsightsSummary(httpMock).flush(mockInsights);
    expectBreakdown(httpMock).flush(mockBreakdown);
    flushPendingSavings(httpMock);
    fixture.detectChanges();
    expect(hub.insights).toBeNull();

    isCurrent.mockReturnValue(true);
    hub.insights = mockInsights;
    hub.refresh();
    expectInsightsSummary(httpMock).flush(
      { code: 'INTERNAL', message: 'boom', title: 'Insights failed', explanation: 'x', recoverable: true },
      { status: 500, statusText: 'Error' },
    );
    const abortErr = Object.assign(new Error('aborted'), { name: 'AbortError' });
    expectBreakdown(httpMock).error(abortErr as unknown as ProgressEvent);
    flushPendingSavings(httpMock);
    fixture.detectChanges();
    expect(hub.summaryError).toBeTruthy();

    hub.loadDetail('plan-1');
    const detailReq = httpMock.expectOne((r) => r.url.startsWith('/api/metrics/detail'));
    isCurrent.mockReturnValue(false);
    detailReq.flush(
      { code: 'INTERNAL', message: 'late', title: 'Detail failed', explanation: 'x', recoverable: true },
      { status: 500, statusText: 'Error' },
    );
    expect(hub.detailError).toBeNull();
  });

  it('scopes filters and csv rows through selected workspace and sparse models', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    const selector = TestBed.inject(WorkspaceSelectorService);
    (selector.workspaces as ReturnType<typeof signal>).set([
      {
        path: '/tmp/project',
        workspaceRoot: '/tmp/project/.ralph-workspace',
        projectRoot: '/tmp/project',
        label: 'project',
        exists: true,
        sections: {},
      },
    ]);
    (selector.selectedWorkspacePath as ReturnType<typeof signal>).set('/tmp/project');
    mountUsageHub(fixture);

    const summaryReq = expectInsightsSummary(httpMock);
    expect(summaryReq.request.params.get('workspaceRoot')).toBe('/tmp/project/.ralph-workspace');
    summaryReq.flush(mockInsights);
    const breakdownReq = expectBreakdown(httpMock);
    expect(breakdownReq.request.params.get('workspaceRoot')).toBe('/tmp/project/.ralph-workspace');
    breakdownReq.flush({
      ...mockBreakdown,
      run_rows: [
        {
          ...mockBreakdown.run_rows[0],
          models: undefined,
          model_exact: 'fallback-model',
        },
      ],
    });
    flushPendingSavings(httpMock);
    fixture.detectChanges();

    const hub = fixture.componentInstance;
    hub.filterRuntime = 'codex';
    hub.filterModel = 'opus';
    (hub as unknown as { loadSavings: () => void }).loadSavings();
    const savings = httpMock.expectOne((r) => r.url.startsWith('/api/benchmarks'));
    expect(savings.request.params.get('runtime')).toBe('codex');
    expect(savings.request.params.get('model')).toBe('opus');
    savings.flush(mockSavingsReport);

    const createObjectURL = vi.fn(() => 'blob:csv');
    const revokeObjectURL = vi.fn();
    const click = vi.fn();
    const anchor = {
      href: '',
      download: '',
      click,
    } as unknown as HTMLAnchorElement;
    vi.stubGlobal('URL', { createObjectURL, revokeObjectURL });
    const createSpy = vi.spyOn(document, 'createElement').mockReturnValue(anchor);
    hub.downloadBreakdownCsv();
    expect(createObjectURL).toHaveBeenCalled();
    expect(click).toHaveBeenCalled();
    createSpy.mockRestore();
    vi.unstubAllGlobals();

    (selector.selectedWorkspacePath as ReturnType<typeof signal>).set('/missing');
    expect(
      (hub as unknown as { selectedWorkspaceRoot: () => string | undefined }).selectedWorkspaceRoot(),
    ).toBeUndefined();
    (selector.selectedWorkspacePath as ReturnType<typeof signal>).set(null);
    expect(
      (hub as unknown as { selectedWorkspaceRoot: () => string | undefined }).selectedWorkspaceRoot(),
    ).toBeUndefined();
  });

  describe('additional conditional and lifecycle edges', () => {
    it('reports isRefreshing and closes detail from loading or error escape paths', () => {
      const fixture = TestBed.createComponent(UsageHubComponent);
      const hub = fixture.componentInstance;
      hub.insights = mockInsights;
      hub.summaryLoading = true;
      expect(hub.isRefreshing).toBe(true);
      hub.summaryLoading = false;
      hub.breakdownLoading = true;
      expect(hub.isRefreshing).toBe(true);
      hub.breakdownLoading = false;
      expect(hub.isRefreshing).toBe(false);

      hub.detailLoading = true;
      hub.closeDetailOnEscape();
      expect(hub.detailLoading).toBe(false);

      hub.detailError = { message: 'x' };
      hub.closeDetailOnEscape();
      expect(hub.detailError).toBeNull();
    });

    it('normalizes empty filter model/date setters and opens non-details drill targets safely', () => {
      const fixture = TestBed.createComponent(UsageHubComponent);
      const hub = fixture.componentInstance;
      vi.spyOn(hub as unknown as { reloadFiltered: () => void }, 'reloadFiltered').mockImplementation(() => {});
      hub.setFilterModel('   ');
      expect(hub.filterModel).toBe('all');
      hub.setFilterDateFrom('   ');
      expect(hub.filterDateFrom).toBe('');
      hub.setFilterDateTo('2026-02-01');
      expect(hub.filterDateTo).toBe('2026-02-01');

      const querySpy = vi.spyOn(document, 'querySelector').mockReturnValue(document.createElement('div'));
      hub.openDrilldown('runs');
      expect(hub.activeDrill).toBe('runs');
      querySpy.mockRestore();

      expect(hub.friendlyModel(undefined)).toBe('Unspecified model');
    });

    it('keeps prior insights/breakdown when a later refresh errors', () => {
      const fixture = TestBed.createComponent(UsageHubComponent);
      mountUsageHub(fixture);
      expectInsightsSummary(httpMock).flush(mockInsights);
      expectBreakdown(httpMock).flush(mockBreakdown);
      flushPendingSavings(httpMock);
      fixture.detectChanges();

      const hub = fixture.componentInstance;
      hub.refresh();
      expectInsightsSummary(httpMock).flush(
        { code: 'INTERNAL', message: 'boom', title: 'Insights failed', explanation: 'x', recoverable: true },
        { status: 500, statusText: 'Error' },
      );
      expectBreakdown(httpMock).flush(
        { code: 'INTERNAL', message: 'boom', title: 'Breakdown failed', explanation: 'x', recoverable: true },
        { status: 500, statusText: 'Error' },
      );
      flushPendingSavings(httpMock);
      fixture.detectChanges();
      expect(hub.insights?.headline.run_count).toBe(2);
      expect(hub.breakdown?.run_rows.length).toBe(1);
      expect(hub.summaryError).toBeTruthy();
      expect(hub.breakdownError).toBeTruthy();
    });
  });
});
