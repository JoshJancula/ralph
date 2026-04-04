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

    expect(fixture.componentInstance.items.length).toBe(0);
    expect(fixture.componentInstance.loading).toBe(false);
  });

  it('fetchPlans records error when listing fails', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs');
    req.flush({ error: 'server' }, { status: 500, statusText: 'Error' });

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

    const item = fixture.componentInstance.items[0];
    fixture.componentInstance.openPlan(item);
    expect(spy).toHaveBeenCalledWith('plans', '', 'PLAN2.md');
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
});
