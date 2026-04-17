import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';

import { NavService } from '../../services/nav.service';
import { UsageHubComponent } from './usage-hub.component';

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
    });
    fixture.detectChanges();

    const component = fixture.componentInstance;
    component.setFilterRuntime('codex');
    expect(component.filterRuntime).toBe('codex');
    component.setFilterKind('orchestration');
    expect(component.filterRuntime).toBe('all');
  });
});
