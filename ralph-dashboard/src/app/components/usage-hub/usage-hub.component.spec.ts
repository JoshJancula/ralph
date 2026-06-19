import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { signal } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';

import type { DiscoverReportResponse, SavingsReport, WorkspaceRegistry } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { UsageHubComponent } from './usage-hub.component';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';

function emptyDiscoverResponse(planKey: string): DiscoverReportResponse {
  return {
    plan_key: planKey,
    path: `/logs/${planKey}/discover-report.json`,
    workspace_root: '',
    project_root: '',
    report: {
      schema_version: 1,
      kind: 'discover_report',
      plan_key: planKey,
      sequence_patterns: [],
      limitations: [],
    },
  };
}

function flushPendingDiscoverRequests(httpMock: HttpTestingController): void {
  const pending = httpMock.match((req) => req.url.includes('/api/metrics/discover/'));
  for (const req of pending) {
    const url = req.request.url;
    const marker = '/api/metrics/discover/';
    const start = url.indexOf(marker) + marker.length;
    const encodedKey = url.slice(start).split('?')[0];
    const planKey = decodeURIComponent(encodedKey);
    req.flush(emptyDiscoverResponse(planKey));
  }
}

function flushPendingSavingsRequests(httpMock: HttpTestingController): void {
  const pending = httpMock.match((req) => req.url === '/api/benchmarks');
  for (const req of pending) {
    req.flush(mockSavingsReport);
  }
}

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
  per_path: {
    pre_tool_rewrite: {
      pre_optimization_bytes: 4096,
      post_optimization_bytes: 2048,
      saved_bytes: 2048,
      count: 3,
      pre_optimization_tokens: 1024,
      post_optimization_tokens: 512,
      saved_tokens: 512,
      token_cap_triggers: 0,
      savings_percent: 50,
    },
    hook_compaction: {
      pre_optimization_bytes: 2048,
      post_optimization_bytes: 1024,
      saved_bytes: 1024,
      count: 1,
      pre_optimization_tokens: 512,
      post_optimization_tokens: 256,
      saved_tokens: 256,
      token_cap_triggers: 0,
    },
    proxy_shell_compaction: {
      pre_optimization_bytes: 1024,
      post_optimization_bytes: 512,
      saved_bytes: 512,
      count: 1,
      pre_optimization_tokens: 256,
      post_optimization_tokens: 128,
      saved_tokens: 128,
      token_cap_triggers: 0,
    },
    result_windowing: {
      pre_optimization_bytes: 1024,
      post_optimization_bytes: 512,
      saved_bytes: 512,
      count: 1,
      pre_optimization_tokens: 256,
      post_optimization_tokens: 128,
      saved_tokens: 128,
      token_cap_triggers: 0,
    },
  },
  cache: {
    cache_read_tokens: 200,
    cache_hit_ratio: 0.65,
  },
  could_have_saved: {
    compaction_measured_not_applied_bytes: 0,
  },
  readback_summary: {
    envelope_count: 2,
    readback_count: 4,
    raw_readback_count: 1,
    compacted_readback_count: 3,
    readback_bytes: 256,
    envelope_original_bytes: 1024,
    full_preview_rereads: 0,
    raw_readback_share: 0.25,
    readback_negation_rate: 0.25,
    gross_readback_bytes: 256,
    gross_readback_tokens: 64,
    net_consumed_bytes: 512,
    net_consumed_tokens: 128,
    effective_windowing_savings_rate: 0.5,
  },
};

describe('UsageHubComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [UsageHubComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    flushPendingDiscoverRequests(httpMock);
    flushPendingSavingsRequests(httpMock);
    httpMock.verify();
  });

  it('builds runtime and model breakdown rows from summary data', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/metrics/summary');
    req.flush({
      overall: {
        input_tokens: 180,
        output_tokens: 100,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 250,
        max_turn_total_tokens: 900,
        cache_hit_ratio: 0.58,
        elapsed_seconds: 21,
        count: 2,
      },
      plans: [
        {
          path: '/logs/plan-1/plan-usage-summary.json',
          plan_key: 'plan-1',
          artifact_ns: 'plan-1',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 10,
          input_tokens: 120,
          output_tokens: 80,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 220,
          max_turn_total_tokens: 900,
          cache_hit_ratio: 0.6471,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'gpt-5.4-mini',
              invocations: 2,
              elapsed_seconds: 10,
              input_tokens: 120,
              output_tokens: 80,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 220,
              max_turn_total_tokens: 900,
              cache_hit_ratio: 0.6471,
            },
          ],
        },
      ],
      orchestrations: [
        {
          path: '/logs/orch-1/orchestration-usage-summary.json',
          plan_key: 'orch-1',
          artifact_ns: 'orch-1',
          stage_id: 'impl',
          started_at: '2026-04-17T09:00:00.000Z',
          runtime: 'claude',
          model: 'sonnet',
          elapsed_seconds: 11,
          input_tokens: 60,
          output_tokens: 20,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 30,
          max_turn_total_tokens: 500,
          cache_hit_ratio: 0.3333,
        },
      ],
      projects: [],
    });
    fixture.detectChanges();

    const component = fixture.componentInstance;
    expect(component.runtimeRows).toHaveLength(2);
    expect(component.modelRows).toHaveLength(2);
    expect(component.detailedBreakdownRuns).toBe(1);
    expect(component.inferredBreakdownRuns).toBe(1);

    const codex = component.runtimeRows.find((row) => row.runtime === 'codex');
    expect(codex).toBeDefined();
    expect(codex?.model_count).toBe(1);
    expect(codex?.invocations).toBe(2);

    const claudeModel = component.modelRows.find((row) => row.runtime === 'claude' && row.model === 'sonnet');
    expect(claudeModel).toBeDefined();
    expect(claudeModel?.invocations).toBe(1);
    expect(claudeModel?.runs).toBe(1);
  });

  it('loads the savings report once metrics summary is available', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    const summaryReq = httpMock.expectOne('/api/metrics/summary');
    summaryReq.flush({
      overall: {
        input_tokens: 180,
        output_tokens: 100,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 250,
        max_turn_total_tokens: 900,
        cache_hit_ratio: 0.58,
        elapsed_seconds: 21,
        count: 2,
      },
      plans: [
        {
          path: '/logs/plan-1/plan-usage-summary.json',
          plan_key: 'plan-1',
          artifact_ns: 'plan-1',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 10,
          input_tokens: 120,
          output_tokens: 80,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 220,
          max_turn_total_tokens: 900,
          cache_hit_ratio: 0.6471,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'gpt-5.4-mini',
              invocations: 2,
              elapsed_seconds: 10,
              input_tokens: 120,
              output_tokens: 80,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 220,
              max_turn_total_tokens: 900,
              cache_hit_ratio: 0.6471,
            },
          ],
        },
      ],
      orchestrations: [
        {
          path: '/logs/orch-1/orchestration-usage-summary.json',
          plan_key: 'orch-1',
          artifact_ns: 'orch-1',
          stage_id: 'impl',
          started_at: '2026-04-17T09:00:00.000Z',
          runtime: 'claude',
          model: 'sonnet',
          elapsed_seconds: 11,
          input_tokens: 60,
          output_tokens: 20,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 30,
          max_turn_total_tokens: 500,
          cache_hit_ratio: 0.3333,
        },
      ],
      projects: [],
    });

    const savingsReq = httpMock.expectOne('/api/benchmarks');
    expect(savingsReq.request.params.has('runtime')).toBe(false);
    savingsReq.flush(mockSavingsReport);

    expect(fixture.componentInstance.savingsReport).toEqual(mockSavingsReport);
    expect(fixture.componentInstance.savingsPathEntries).toHaveLength(4);
  });

  it('re-fetches savings when the runtime filter changes', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 180,
        output_tokens: 100,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 250,
        max_turn_total_tokens: 900,
        cache_hit_ratio: 0.58,
        elapsed_seconds: 21,
        count: 2,
      },
      plans: [
        {
          path: '/logs/plan-1/plan-usage-summary.json',
          plan_key: 'plan-1',
          artifact_ns: 'plan-1',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 10,
          input_tokens: 120,
          output_tokens: 80,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 220,
          max_turn_total_tokens: 900,
          cache_hit_ratio: 0.6471,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'gpt-5.4-mini',
              invocations: 2,
              elapsed_seconds: 10,
              input_tokens: 120,
              output_tokens: 80,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 220,
              max_turn_total_tokens: 900,
              cache_hit_ratio: 0.6471,
            },
          ],
        },
      ],
      orchestrations: [],
      projects: [],
    });
    httpMock.expectOne('/api/benchmarks').flush(mockSavingsReport);

    fixture.componentInstance.setFilterRuntime('codex');
    const savingsReq = httpMock.expectOne((req) => req.url === '/api/benchmarks');
    expect(savingsReq.request.params.get('runtime')).toBe('codex');
    savingsReq.flush(mockSavingsReport);
  });

  it('applies runtime and date filters to the breakdown tables', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/metrics/summary');
    req.flush({
      overall: {
        input_tokens: 180,
        output_tokens: 100,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 250,
        max_turn_total_tokens: 900,
        cache_hit_ratio: 0.58,
        elapsed_seconds: 21,
        count: 2,
      },
      plans: [
        {
          path: '/logs/plan-1/plan-usage-summary.json',
          plan_key: 'plan-1',
          artifact_ns: 'plan-1',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 10,
          input_tokens: 120,
          output_tokens: 80,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 220,
          max_turn_total_tokens: 900,
          cache_hit_ratio: 0.6471,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'gpt-5.4-mini',
              invocations: 2,
              elapsed_seconds: 10,
              input_tokens: 120,
              output_tokens: 80,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 220,
              max_turn_total_tokens: 900,
              cache_hit_ratio: 0.6471,
            },
          ],
        },
      ],
      orchestrations: [
        {
          path: '/logs/orch-1/orchestration-usage-summary.json',
          plan_key: 'orch-1',
          artifact_ns: 'orch-1',
          stage_id: 'impl',
          started_at: '2026-04-17T09:00:00.000Z',
          runtime: 'claude',
          model: 'sonnet',
          elapsed_seconds: 11,
          input_tokens: 60,
          output_tokens: 20,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 30,
          max_turn_total_tokens: 500,
          cache_hit_ratio: 0.3333,
        },
      ],
      projects: [],
    });
    fixture.detectChanges();

    const component = fixture.componentInstance;
    component.setFilterRuntime('codex');
    expect(component.runtimeRows).toHaveLength(1);
    expect(component.runtimeRows[0].runtime).toBe('codex');
    expect(component.filteredRunCount).toBe(1);

    component.setFilterRuntime('all');
    component.setFilterDateFrom('2026-04-17');
    expect(component.runtimeRows).toHaveLength(1);
    expect(component.runtimeRows[0].runtime).toBe('claude');
    expect(component.filteredRunCount).toBe(1);
  });

  it('goToPlans delegates to NavService.navigate', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 0,
        count: 0,
      },
      plans: [],
      orchestrations: [],
      projects: [],
    });

    fixture.componentInstance.goToPlans();
    expect(spy).toHaveBeenCalledWith('plans');
  });

  it('surfaces API error body when metrics request fails', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/metrics/summary');
    req.flush({ error: 'Service unavailable' }, { status: 503, statusText: 'Unavailable' });
    fixture.detectChanges();

    expect(fixture.componentInstance.error).toBe('Service unavailable');
    expect(fixture.componentInstance.loading).toBe(false);
    expect(fixture.componentInstance.summary).toBeNull();
  });

  it('normalizes helper inputs and workspace scoping fallbacks', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    const component = fixture.componentInstance as any;
    const workspaceSelector = TestBed.inject(WorkspaceSelectorService);

    workspaceSelector.workspaces.set([
      { path: '/work/a', label: 'Workspace A', exists: true, root: '', projectRoot: '', workspaceRoot: '/work/a' },
      { path: '/work/b', label: undefined as unknown as string, exists: true, root: '', projectRoot: '', workspaceRoot: '/work/b' },
    ] as WorkspaceRegistry[]);
    workspaceSelector.selectedWorkspacePath.set(null);

    expect(component.normalizeKindFilter('plan')).toBe('plan');
    expect(component.normalizeKindFilter('bogus')).toBe('all');
    expect(component.normalizeSelection('  codex  ')).toBe('codex');
    expect(component.normalizeSelection('')).toBe('all');
    expect(component.normalizeRuntime('')).toBe('unknown');
    expect(component.normalizeRuntime('claude')).toBe('claude');
    expect(component.normalizeModel('')).toBe('(unspecified)');
    expect(component.normalizeModel('sonnet')).toBe('sonnet');
    expect(component.normalizeInvocations(0)).toBe(1);
    expect(component.normalizeInvocations(2.4)).toBe(2);
    expect(component.formatSavingsDateRange(null)).toBe('');
    expect(component.getWorkspaceDisplayName('/missing/path')).toBe('(unknown)');
    expect(component.getWorkspaceDisplayName('/work/a/logs/plan-1')).toBe('Workspace A');
    expect(component.getWorkspaceDisplayName('/work/b/logs/plan-2')).toBe('b');
    expect(component.isShowingAllWorkspaces()).toBe(true);

    workspaceSelector.selectedWorkspacePath.set('/work/a');
    expect(component.isShowingAllWorkspaces()).toBe(false);

    const selectedRecord = {
      item: { workspace_root: '/work/a' },
    } as { item: { workspace_root: string } };
    const otherRecord = {
      item: { workspace_root: '/work/b' },
    } as { item: { workspace_root: string } };
    expect(component.passesWorkspaceScopeFilter(selectedRecord)).toBe(true);
    expect(component.passesWorkspaceScopeFilter(otherRecord)).toBe(false);
    workspaceSelector.selectedWorkspacePath.set('/work/b');
    expect(component.getWorkspaceDisplayName('/work/b/logs/plan-2')).toBe('b');
    workspaceSelector.selectedWorkspacePath.set(null);

    expect(component.passesDateFilter(null, null, null)).toBe(true);
    expect(component.passesDateFilter(null, 10, null)).toBe(false);
    expect(component.passesDateFilter(5, 10, null)).toBe(false);
    expect(component.passesDateFilter(25, null, 20)).toBe(false);
    expect(component.passesDateFilter(15, 10, 20)).toBe(true);

    component.filterModel = 'missing';
    component.recomputeModelOptions({
      overall: {
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 0,
        count: 1,
      },
      plans: [
        {
          path: '/logs/plan-1/plan-usage-summary.json',
          plan_key: 'plan-1',
          artifact_ns: 'plan-1',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 1,
          input_tokens: 1,
          output_tokens: 1,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'sonnet',
              invocations: 1,
              elapsed_seconds: 1,
              input_tokens: 1,
              output_tokens: 1,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
          ],
        },
      ],
      orchestrations: [],
      projects: [],
    });
    expect(component.modelOptions).toContain('sonnet');
    expect(component.filterModel).toBe('all');

    workspaceSelector.workspaces.set([
      { path: '/work/c', label: 'Workspace C', exists: true, root: '', projectRoot: '', workspaceRoot: undefined as unknown as string },
    ] as WorkspaceRegistry[]);
    workspaceSelector.selectedWorkspacePath.set('/work/c');
    expect(component.passesWorkspaceScopeFilter({ item: { workspace_root: '/anywhere' } } as any)).toBe(true);

    component.recomputeModelOptions(null);
    expect(component.modelOptions).toEqual([]);
    expect(component.filterModel).toBe('all');

    component.filterRuntime = 'codex';
    component.recomputeRuntimeOptions(null);
    expect(component.runtimeOptions).toEqual([]);
    expect(component.filterRuntime).toBe('all');

    component.applyFilters({
      overall: {
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 0,
        count: 2,
      },
      plans: [
        {
          path: '/logs/plan-a/plan-usage-summary.json',
          plan_key: 'plan-a',
          artifact_ns: 'plan-a',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 1,
          input_tokens: 1,
          output_tokens: 1,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          tool_calls_total: 1,
          tool_calls: { ralph_proxy_calls: 1 } as any,
          overlay: {
            native_hooks_effective: true,
            mcp_effective: false,
            native_hook_events: 1,
            hook_compactions: 0,
            hook_rewrites: 0,
            hook_original_bytes: 100,
            hook_compacted_bytes: 50,
            hook_bytes_saved: 50,
            runtime_overlay_mode: 'native',
            runtime_overlay_warnings: [],
          },
        },
      ],
      orchestrations: [
        {
          path: '/logs/orch-b/orchestration-usage-summary.json',
          plan_key: 'orch-b',
          artifact_ns: 'orch-b',
          stage_id: 'beta',
          started_at: '2026-04-17T09:00:00.000Z',
          runtime: 'claude',
          model: 'sonnet',
          elapsed_seconds: 2,
          input_tokens: 2,
          output_tokens: 2,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          tool_calls_total: 1,
          tool_calls: { ralph_proxy_calls: 1 } as any,
          overlay: {
            native_hooks_effective: false,
            mcp_effective: true,
            native_hook_events: 1,
            hook_compactions: 0,
            hook_rewrites: 0,
            hook_original_bytes: 100,
            hook_compacted_bytes: 100,
            hook_bytes_saved: 0,
            runtime_overlay_mode: 'mcp',
            runtime_overlay_warnings: ['warn'],
          },
        },
      ],
      projects: [],
    });
    expect(component.toolCallRunRows).toHaveLength(2);

    component.applyFilters(null);
    expect(component.runtimeRows).toEqual([]);
    expect(component.modelRows).toEqual([]);
  });

  it('setFilterKind plan keeps only plan runs', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 10,
        output_tokens: 10,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 1,
        count: 2,
      },
      plans: [
        {
          path: '/logs/p1/plan-usage-summary.json',
          plan_key: 'p1',
          artifact_ns: 'p1',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 1,
          input_tokens: 5,
          output_tokens: 5,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'm1',
              invocations: 1,
              elapsed_seconds: 1,
              input_tokens: 5,
              output_tokens: 5,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
          ],
        },
      ],
      orchestrations: [
        {
          path: '/logs/o1/orchestration-usage-summary.json',
          plan_key: 'o1',
          artifact_ns: 'o1',
          started_at: '2026-04-17T09:00:00.000Z',
          runtime: 'claude',
          model: 'sonnet',
          elapsed_seconds: 1,
          input_tokens: 5,
          output_tokens: 5,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
        },
      ],
      projects: [],
    });
    fixture.detectChanges();

    const component = fixture.componentInstance;
    component.setFilterKind('plan');
    expect(component.filteredRunCount).toBe(1);
    expect(component.runtimeRows.every((r) => r.runtime === 'codex')).toBe(true);

    component.setFilterKind('orchestration');
    expect(component.filteredRunCount).toBe(1);
    expect(component.runtimeRows[0].runtime).toBe('claude');
  });

  it('clearFilters resets kind, runtime, model, and date filters', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 10,
        output_tokens: 10,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 1,
        count: 1,
      },
      plans: [
        {
          path: '/logs/p1/plan-usage-summary.json',
          plan_key: 'p1',
          artifact_ns: 'p1',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 1,
          input_tokens: 10,
          output_tokens: 10,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'm1',
              invocations: 1,
              elapsed_seconds: 1,
              input_tokens: 10,
              output_tokens: 10,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
          ],
        },
      ],
      orchestrations: [],
      projects: [],
    });
    fixture.detectChanges();

    const component = fixture.componentInstance;
    component.setFilterKind('plan');
    component.setFilterRuntime('codex');
    component.setFilterModel('m1');
    component.setFilterDateFrom('2026-04-16');
    component.setFilterDateTo('2026-04-16');
    component.clearFilters();

    expect(component.filterKind).toBe('all');
    expect(component.filterRuntime).toBe('all');
    expect(component.filterModel).toBe('all');
    expect(component.filterDateFrom).toBe('');
    expect(component.filterDateTo).toBe('');
  });

  it('setFilterModel keeps only matching model rows', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 20,
        output_tokens: 20,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 2,
        count: 1,
      },
      plans: [
        {
          path: '/logs/p1/plan-usage-summary.json',
          plan_key: 'p1',
          artifact_ns: 'p1',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 2,
          input_tokens: 20,
          output_tokens: 20,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'alpha',
              invocations: 1,
              elapsed_seconds: 1,
              input_tokens: 10,
              output_tokens: 10,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
            {
              runtime: 'codex',
              model: 'beta',
              invocations: 1,
              elapsed_seconds: 1,
              input_tokens: 10,
              output_tokens: 10,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
          ],
        },
      ],
      orchestrations: [],
      projects: [],
    });
    fixture.detectChanges();

    const component = fixture.componentInstance;
    component.setFilterModel('beta');
    expect(component.modelRows).toHaveLength(1);
    expect(component.modelRows[0].model).toBe('beta');
  });

  it('uses summary-level runtime and model when model_breakdown is empty', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 5,
        output_tokens: 5,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 1,
        count: 1,
      },
      plans: [
        {
          path: '/logs/p1/plan-usage-summary.json',
          plan_key: 'p1',
          artifact_ns: 'p1',
          started_at: '2026-04-16T09:00:00.000Z',
          runtime: 'opencode',
          model: 'kimi',
          elapsed_seconds: 1,
          input_tokens: 5,
          output_tokens: 5,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [],
        },
      ],
      orchestrations: [],
      projects: [],
    });
    fixture.detectChanges();

    const component = fixture.componentInstance;
    expect(component.detailedBreakdownRuns).toBe(0);
    expect(component.inferredBreakdownRuns).toBe(1);
    expect(component.modelRows.some((r) => r.runtime === 'opencode' && r.model === 'kimi')).toBe(true);
  });

  it('treats non-positive model_breakdown invocations as 1', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 1,
        output_tokens: 1,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 1,
        count: 1,
      },
      plans: [
        {
          path: '/logs/p1/plan-usage-summary.json',
          plan_key: 'p1',
          artifact_ns: 'p1',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 1,
          input_tokens: 1,
          output_tokens: 1,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'm1',
              invocations: 0,
              elapsed_seconds: 1,
              input_tokens: 1,
              output_tokens: 1,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
          ],
        },
      ],
      orchestrations: [],
      projects: [],
    });
    fixture.detectChanges();

    expect(fixture.componentInstance.modelRows[0].invocations).toBe(1);
  });

  it('excludes runs with no timestamps when a date filter is set', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 1,
        output_tokens: 1,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 1,
        count: 1,
      },
      plans: [
        {
          path: '/logs/p1/plan-usage-summary.json',
          plan_key: 'p1',
          artifact_ns: 'p1',
          elapsed_seconds: 1,
          input_tokens: 1,
          output_tokens: 1,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'm1',
              invocations: 1,
              elapsed_seconds: 1,
              input_tokens: 1,
              output_tokens: 1,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
          ],
        },
      ],
      orchestrations: [],
      projects: [],
    });
    fixture.detectChanges();

    const component = fixture.componentInstance;
    expect(component.totalRunCount).toBe(1);
    component.setFilterDateFrom('2026-04-16');
    expect(component.filteredRunCount).toBe(0);
    expect(component.runtimeRows).toHaveLength(0);
  });

  it('resets runtime filter when it is not available for the selected kind', () => {
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 10,
        output_tokens: 10,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 2,
        count: 2,
      },
      plans: [
        {
          path: '/logs/p1/plan-usage-summary.json',
          plan_key: 'p1',
          artifact_ns: 'p1',
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 1,
          input_tokens: 5,
          output_tokens: 5,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'm1',
              invocations: 1,
              elapsed_seconds: 1,
              input_tokens: 5,
              output_tokens: 5,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
          ],
        },
      ],
      orchestrations: [
        {
          path: '/logs/o1/orchestration-usage-summary.json',
          plan_key: 'o1',
          artifact_ns: 'o1',
          started_at: '2026-04-17T09:00:00.000Z',
          runtime: 'claude',
          model: 'sonnet',
          elapsed_seconds: 1,
          input_tokens: 5,
          output_tokens: 5,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
        },
      ],
      projects: [],
    });
    fixture.detectChanges();

    const component = fixture.componentInstance;
    component.setFilterRuntime('codex');
    expect(component.filterRuntime).toBe('codex');
    component.setFilterKind('orchestration');
    expect(component.filterRuntime).toBe('all');
  });
});

describe('UsageHubComponent multi-project behavior', () => {
  beforeEach(() => {
    TestBed.resetTestingModule();
  });

  it('scopes breakdown runs to the selected workspace_root when plan_key collides across projects', async () => {
    const projA = '/mock/proj-a';
    const projB = '/mock/proj-b';
    const wsRootA = `${projA}/.ralph-workspace`;
    const wsRootB = `${projB}/.ralph-workspace`;
    const registry: WorkspaceRegistry[] = [
      { path: projA, workspaceRoot: wsRootA, projectRoot: projA, label: 'proj-a', exists: true },
      { path: projB, workspaceRoot: wsRootB, projectRoot: projB, label: 'proj-b', exists: true },
    ];

    await TestBed.configureTestingModule({
      imports: [UsageHubComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
      providers: [
        {
          provide: WorkspaceSelectorService,
          useValue: {
            workspaces: signal(registry),
            selectedWorkspacePath: signal(projA),
          },
        },
      ],
    }).compileComponents();

    const httpMock = TestBed.inject(HttpTestingController);
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 300,
        output_tokens: 20,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 20,
        count: 2,
      },
      plans: [
        {
          path: `${wsRootA}/logs/feature/plan-usage-summary.json`,
          plan_key: 'feature',
          artifact_ns: 'feature',
          workspace_root: wsRootA,
          project_root: projA,
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 10,
          input_tokens: 100,
          output_tokens: 10,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [
            {
              runtime: 'codex',
              model: 'm-a',
              invocations: 1,
              elapsed_seconds: 10,
              input_tokens: 100,
              output_tokens: 10,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
          ],
        },
        {
          path: `${wsRootB}/logs/feature/plan-usage-summary.json`,
          plan_key: 'feature',
          artifact_ns: 'feature',
          workspace_root: wsRootB,
          project_root: projB,
          started_at: '2026-04-16T10:00:00.000Z',
          elapsed_seconds: 10,
          input_tokens: 200,
          output_tokens: 10,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [
            {
              runtime: 'claude',
              model: 'm-b',
              invocations: 1,
              elapsed_seconds: 10,
              input_tokens: 200,
              output_tokens: 10,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
          ],
        },
      ],
      orchestrations: [],
      projects: [],
    });
    fixture.detectChanges();

    const component = fixture.componentInstance;
    expect(component.totalRunCount).toBe(1);
    expect(component.filteredRunCount).toBe(1);
    expect(component.runtimeRows).toHaveLength(1);
    expect(component.runtimeRows[0].runtime).toBe('codex');
    expect(component.modelRows).toHaveLength(1);
    expect(component.modelRows[0].input_tokens).toBe(100);

    flushPendingDiscoverRequests(httpMock);
    flushPendingSavingsRequests(httpMock);
    httpMock.verify();
  });

  it('renders per-project rollup headings when multiple projects are registered', async () => {
    const projA = '/mock/proj-a';
    const projB = '/mock/proj-b';
    const wsRootA = `${projA}/.ralph-workspace`;
    const wsRootB = `${projB}/.ralph-workspace`;
    const registry: WorkspaceRegistry[] = [
      { path: projA, workspaceRoot: wsRootA, projectRoot: projA, label: 'proj-a', exists: true },
      { path: projB, workspaceRoot: wsRootB, projectRoot: projB, label: 'proj-b', exists: true },
    ];

    await TestBed.configureTestingModule({
      imports: [UsageHubComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
      providers: [
        {
          provide: WorkspaceSelectorService,
          useValue: {
            workspaces: signal(registry),
            selectedWorkspacePath: signal<string | null>(null),
          },
        },
      ],
    }).compileComponents();

    const httpMock = TestBed.inject(HttpTestingController);
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 10,
        output_tokens: 10,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 2,
        count: 2,
      },
      plans: [],
      orchestrations: [],
      projects: [
        {
          workspace_root: wsRootA,
          project_root: projA,
          label: 'Alpha',
          overall: {
            input_tokens: 5,
            output_tokens: 5,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
            max_turn_total_tokens: 0,
            cache_hit_ratio: 0,
            elapsed_seconds: 1,
            count: 1,
          },
          plans: [],
          orchestrations: [],
        },
        {
          workspace_root: wsRootB,
          project_root: projB,
          label: 'Beta',
          overall: {
            input_tokens: 5,
            output_tokens: 5,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
            max_turn_total_tokens: 0,
            cache_hit_ratio: 0,
            elapsed_seconds: 1,
            count: 1,
          },
          plans: [],
          orchestrations: [],
        },
      ],
    });
    fixture.detectChanges();

    const text = (fixture.nativeElement as HTMLElement).textContent ?? '';
    expect(text).toContain('By project');
    expect(text).toContain('Alpha');
    expect(text).toContain('Beta');

    flushPendingSavingsRequests(httpMock);
    httpMock.verify();
  });

  it('Plan Runs table clip cells expose full plan_key and model in title', async () => {
    const projA = '/mock/proj-a';
    const projB = '/mock/proj-b';
    const wsRootA = `${projA}/.ralph-workspace`;
    const wsRootB = `${projB}/.ralph-workspace`;
    const longPlan = `${'x'.repeat(60)}_suffix.plan`;
    const longModel = 'vendor/subsystem/model-name-extra-long';
    const registry: WorkspaceRegistry[] = [
      { path: projA, workspaceRoot: wsRootA, projectRoot: projA, label: 'proj-a', exists: true },
      { path: projB, workspaceRoot: wsRootB, projectRoot: projB, label: 'proj-b', exists: true },
    ];

    await TestBed.configureTestingModule({
      imports: [UsageHubComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
      providers: [
        {
          provide: WorkspaceSelectorService,
          useValue: {
            workspaces: signal(registry),
            selectedWorkspacePath: signal<string | null>(null),
            getWorkspaceForMetricPath: (p: string) =>
              p.startsWith(wsRootA) ? projA : p.startsWith(wsRootB) ? projB : null,
          },
        },
      ],
    }).compileComponents();

    const httpMock = TestBed.inject(HttpTestingController);
    const fixture = TestBed.createComponent(UsageHubComponent);
    fixture.detectChanges();

    httpMock.expectOne('/api/metrics/summary').flush({
      overall: {
        input_tokens: 1,
        output_tokens: 1,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0,
        elapsed_seconds: 1,
        count: 1,
      },
      plans: [
        {
          path: `${wsRootA}/logs/${longPlan}/plan-usage-summary.json`,
          plan_key: longPlan,
          artifact_ns: longPlan,
          workspace_root: wsRootA,
          runtime: 'codex',
          model: longModel,
          started_at: '2026-04-16T09:00:00.000Z',
          elapsed_seconds: 1,
          input_tokens: 1,
          output_tokens: 1,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          model_breakdown: [
            {
              runtime: 'codex',
              model: longModel,
              invocations: 1,
              elapsed_seconds: 1,
              input_tokens: 1,
              output_tokens: 1,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              max_turn_total_tokens: 0,
              cache_hit_ratio: 0,
            },
          ],
        },
      ],
      orchestrations: [],
      projects: [],
    });
    fixture.detectChanges();

    const host = fixture.nativeElement as HTMLElement;
    const planRow = host.querySelector('.usage-row.plan-columns:not(.usage-header)');
    expect(planRow).toBeTruthy();
    const clips = planRow!.querySelectorAll('.cell-clip');
    expect(clips.length).toBeGreaterThanOrEqual(4);
    const planKeyCell = clips[1] as HTMLElement;
    const modelCell = clips[3] as HTMLElement;
    expect(planKeyCell.getAttribute('title')).toBe(longPlan);
    expect(modelCell.getAttribute('title')).toBe(longModel);
    expect(getComputedStyle(planKeyCell).whiteSpace).toBe('nowrap');

    flushPendingDiscoverRequests(httpMock);
    flushPendingSavingsRequests(httpMock);
    httpMock.verify();
  });
});
