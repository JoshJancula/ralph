import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { PlanHubComponent } from './plan-hub.component';
import { NavService } from '../../services/nav.service';

const testRoutes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: '**', redirectTo: 'plans' },
];

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

function flushMetricsSummary(httpMock: HttpTestingController, body = defaultMetricsSummary): void {
  const req = httpMock.expectOne('/api/metrics/summary');
  req.flush(body);
}

const defaultMetricsSummary = {
  overall: {
    input_tokens: 1234,
    output_tokens: 5678,
    cache_creation_input_tokens: 90,
    cache_read_input_tokens: 12,
    max_turn_total_tokens: 0,
    cache_hit_ratio: 0,
    elapsed_seconds: 45.6,
    count: 2,
  },
  plans: [
    {
      path: '/logs/plan-1/plan-usage-summary.json',
      plan_key: 'plan-1',
      artifact_ns: 'plan-1',
      elapsed_seconds: 5,
      input_tokens: 10,
      output_tokens: 20,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 1,
      max_turn_total_tokens: 0,
      cache_hit_ratio: 0,
    },
  ],
  orchestrations: [
    {
      path: '/logs/orch-1/orchestration-usage-summary.json',
      plan_key: 'orch-1',
      artifact_ns: 'orch-1',
      stage_id: 'build',
      elapsed_seconds: 8.5,
      input_tokens: 30,
      output_tokens: 40,
      cache_creation_input_tokens: 2,
      cache_read_input_tokens: 3,
      max_turn_total_tokens: 0,
      cache_hit_ratio: 0,
    },
  ],
};

const metricsWithNewFields = {
  overall: {
    input_tokens: 100,
    output_tokens: 20,
    cache_creation_input_tokens: 10,
    cache_read_input_tokens: 40,
    max_turn_total_tokens: 55000,
    cache_hit_ratio: 0.267,
    elapsed_seconds: 12,
    count: 1,
  },
  plans: [
    {
      path: '/logs/plan-x/plan-usage-summary.json',
      plan_key: 'plan-x',
      artifact_ns: 'plan-x',
      elapsed_seconds: 12,
      input_tokens: 100,
      output_tokens: 20,
      cache_creation_input_tokens: 10,
      cache_read_input_tokens: 40,
      max_turn_total_tokens: 55000,
      cache_hit_ratio: 0.267,
    },
  ],
  orchestrations: [],
};

describe('PlanHubComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [PlanHubComponent, HttpClientTestingModule, RouterTestingModule.withRoutes(testRoutes)],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('fetchPlans sorts directories by mtime', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [
        { name: 'PLAN1', path: 'PLAN1/', type: 'dir', size: 0, mtime: 100 },
        { name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 200 },
        { name: 'readme.md', path: 'readme.md', type: 'file', size: 1, mtime: 50 },
      ],
    });
    flushMetricsSummary(httpMock);

    const { items, loading } = fixture.componentInstance;
    expect(loading).toBe(false);
    expect(items.map((i) => i.name)).toEqual(['PLAN2', 'PLAN1']);
  });

  it('fetchPlans leaves empty list when no directories', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [],
    });
    flushMetricsSummary(httpMock);

    expect(fixture.componentInstance.items.length).toBe(0);
    expect(fixture.componentInstance.loading).toBe(false);
  });

  it('fetchPlans records error when listing fails', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({ error: 'server' }, { status: 500, statusText: 'Error' });
    flushMetricsSummary(httpMock);

    expect(fixture.componentInstance.error.length).toBeGreaterThan(0);
    expect(fixture.componentInstance.loading).toBe(false);
  });

  it('openPlan delegates to NavService.navigate', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });
    flushMetricsSummary(httpMock);

    const item = fixture.componentInstance.items[0];
    fixture.componentInstance.openPlan(item);
    expect(spy).toHaveBeenCalledWith('plans', '', 'PLAN2.md');
  });

  it('openUsage delegates to NavService.navigate', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();
    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({ root: 'plans', path: '', parent: null, entries: [] });
    flushMetricsSummary(httpMock);

    fixture.componentInstance.openUsage();
    expect(spy).toHaveBeenCalledWith('usage');
  });

  it('viewLogs delegates to NavService.navigate with logs root', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });
    flushMetricsSummary(httpMock);

    const item = fixture.componentInstance.items[0];
    fixture.componentInstance.viewLogs(item);

    // Flush the async API call that viewLogs makes
    tick();
    const viewLogsReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2');
    viewLogsReq.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [],
    });
    tick();

    expect(spy).toHaveBeenCalledWith('logs', 'PLAN2', null);
  }));

  it('viewLogs navigates directly when log file is found', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });
    flushMetricsSummary(httpMock);

    const item = fixture.componentInstance.items[0];
    fixture.componentInstance.viewLogs(item);

    tick();
    const viewLogsReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2');
    viewLogsReq.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [
        { name: 'output.log', path: 'PLAN2/output.log', type: 'file', size: 100, mtime: 1000 },
      ],
    });
    tick();

    expect(spy).toHaveBeenCalledWith('logs', null, 'PLAN2/output.log');
  }));

  it('viewLogs looks in subdirectories when no logs at root', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });
    flushMetricsSummary(httpMock);

    const item = fixture.componentInstance.items[0];
    fixture.componentInstance.viewLogs(item);

    tick();
    const viewLogsReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2');
    viewLogsReq.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [
        { name: 'run-001', path: 'PLAN2/run-001/', type: 'dir', size: 0, mtime: 2000 },
      ],
    });
    tick();

    // Should fetch subdirectory
    const subdirReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2/run-001');
    subdirReq.flush({
      root: 'logs',
      path: 'PLAN2/run-001',
      parent: 'PLAN2',
      entries: [
        { name: 'output.log', path: 'PLAN2/run-001/output.log', type: 'file', size: 100, mtime: 1000 },
      ],
    });
    tick();

    expect(spy).toHaveBeenCalledWith('logs', null, 'PLAN2/run-001/output.log');
  }));

  it('viewLogs navigates to directory when subdirectory has no logs', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });
    flushMetricsSummary(httpMock);

    const item = fixture.componentInstance.items[0];
    fixture.componentInstance.viewLogs(item);

    tick();
    const viewLogsReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2');
    viewLogsReq.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [
        { name: 'run-001', path: 'PLAN2/run-001/', type: 'dir', size: 0, mtime: 2000 },
      ],
    });
    tick();

    // Subdirectory has no logs
    const subdirReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2/run-001');
    subdirReq.flush({
      root: 'logs',
      path: 'PLAN2/run-001',
      parent: 'PLAN2',
      entries: [],
    });
    tick();

    expect(spy).toHaveBeenCalledWith('logs', null, null);
  }));

  it('viewLogs handles error when subdirectory fetch fails', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });
    flushMetricsSummary(httpMock);

    const item = fixture.componentInstance.items[0];
    fixture.componentInstance.viewLogs(item);

    tick();
    const viewLogsReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2');
    viewLogsReq.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [
        { name: 'run-001', path: 'PLAN2/run-001/', type: 'dir', size: 0, mtime: 2000 },
      ],
    });
    tick();

    // Subdirectory fetch fails
    const subdirReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2/run-001');
    subdirReq.flush('error', { status: 500, statusText: 'Error' });
    tick();

    expect(spy).toHaveBeenCalledWith('logs', 'PLAN2', null);
  }));

  it('viewLogs navigates to directory when listing has no log files or subdirs', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });
    flushMetricsSummary(httpMock);

    const item = fixture.componentInstance.items[0];
    fixture.componentInstance.viewLogs(item);

    tick();
    const viewLogsReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2');
    viewLogsReq.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [
        { name: 'readme.md', path: 'PLAN2/readme.md', type: 'file', size: 100, mtime: 1000 },
      ],
    });
    tick();

    // No log files and no subdirectories, so should navigate to dir
    expect(spy).toHaveBeenCalledWith('logs', 'PLAN2', null);
  }));

  it('renders metrics summary and fallback states', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    fixture.detectChanges();

    const listReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    listReq.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });

    flushMetricsSummary(httpMock);
    expect(fixture.componentInstance.metricsSummary).toMatchObject(defaultMetricsSummary);
  });

  it('renders per-folder elapsed and tokens on plan cards', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    fixture.detectChanges();

    const listReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    listReq.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [
        { name: 'plan-1', path: 'plan-1/', type: 'dir', size: 0, mtime: 2 },
        { name: 'orch-1', path: 'orch-1/', type: 'dir', size: 0, mtime: 1 },
      ],
    });
    flushMetricsSummary(httpMock);
    fixture.detectChanges();

    const text = (fixture.nativeElement as HTMLElement).textContent ?? '';
    const comp = fixture.componentInstance;
    expect(comp.formatSeconds(5)).toBe('5s');
    expect(comp.formatSeconds(8.5)).toBe('8.5s');
    expect(text).toContain('31');
    expect(text).toContain('75');
  });

  it('renders cache_hit_ratio and max_turn_total_tokens columns in the plan metrics table', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    fixture.detectChanges();

    const listReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    listReq.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'plan-x', path: 'plan-x/', type: 'dir', size: 0, mtime: 1 }],
    });

    flushMetricsSummary(httpMock, metricsWithNewFields);
    fixture.detectChanges();

    const text = (fixture.nativeElement as HTMLElement).textContent ?? '';
    // cache_hit_ratio 0.267 -> "26.7%"
    expect(text).toContain('26.7%');
    // max_turn_total_tokens 55000 formatted with Intl.NumberFormat
    expect(text).toContain('55');
  });

  it('formatPercent returns "--" for zero and non-finite values', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const comp = fixture.componentInstance;
    expect(comp.formatPercent(0)).toBe('--');
    expect(comp.formatPercent(NaN)).toBe('--');
    expect(comp.formatPercent(0.5)).toBe('50.0%');
  });

  it('formatPeakTurn returns "--" for zero values', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    fixture.detectChanges();
    // Flush HTTP requests triggered by ngOnInit before making assertions.
    httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs').flush({ root: 'plans', path: '', parent: null, entries: [] });
    httpMock.expectOne('/api/metrics/summary').flush(defaultMetricsSummary);

    const comp = fixture.componentInstance;
    expect(comp.formatPeakTurn(0)).toBe('--');
    expect(comp.formatPeakTurn(55000)).toContain('55');
  });

  it('shows a metrics fallback message when metrics fail', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    fixture.detectChanges();

    const listReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    listReq.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });

    const metricsReq = httpMock.expectOne('/api/metrics/summary');
    metricsReq.flush({ error: 'metrics unavailable' }, { status: 500, statusText: 'Error' });

    expect(fixture.componentInstance.metricsError).toContain('metrics unavailable');
    expect(fixture.componentInstance.items.map((item) => item.name)).toEqual(['PLAN2']);
  });
});
