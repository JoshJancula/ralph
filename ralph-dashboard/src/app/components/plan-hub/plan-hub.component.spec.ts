import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { PlanHubComponent } from './plan-hub.component';
import { NavService } from '../../services/nav.service';

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

describe('PlanHubComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    window.location.hash = '';
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [PlanHubComponent, HttpClientTestingModule],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
    window.location.hash = '';
  });

  it('fetchPlans sorts directories by mtime', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'plans');
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

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
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

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
    req.flush({ error: 'server' }, { status: 500, statusText: 'Error' });

    expect(fixture.componentInstance.error.length).toBeGreaterThan(0);
    expect(fixture.componentInstance.loading).toBe(false);
  });

  it('openPlan delegates to NavService.navigate', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });

    const item = fixture.componentInstance.items[0];
    fixture.componentInstance.openPlan(item);
    expect(spy).toHaveBeenCalledWith('plans', 'PLAN2/', '');
  });

  it('viewLogs delegates to NavService.navigate with logs root', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
    req.flush({
      root: 'plans',
      path: '',
      parent: null,
      entries: [{ name: 'PLAN2', path: 'PLAN2/', type: 'dir', size: 0, mtime: 1 }],
    });

    const item = fixture.componentInstance.items[0];
    fixture.componentInstance.viewLogs(item);
    expect(spy).toHaveBeenCalledWith('logs', 'PLAN2/', '');
  });
});
