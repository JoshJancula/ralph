import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ComponentFixture } from '@angular/core';
import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { Router } from '@angular/router';
import { PlanHubComponent } from './plan-hub.component';
import { PlanInventoryResponse } from '../../services/api.service';
import { NavService } from '../../services/nav.service';

const testRoutes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: '**', redirectTo: 'plans' },
];

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

const mockPlanResponse: PlanInventoryResponse = {
  items: [
    {
      id: 'plan-1',
      name: 'PLAN1',
      path: 'plans/PLAN1.md',
      projectRoot: '/mock/proj',
      type: 'leaf',
      planName: 'My First Plan',
      overview: 'A test plan',
      isProject: false,
      checkboxProgress: { completed: 5, total: 10 },
      currentTodo: { id: 'todo-1', content: 'Fix something' },
      lastActivityMs: Date.now() - 1000,
      hasLatestRun: true,
    },
    {
      id: 'plan-2',
      name: 'PLAN2',
      path: 'plans/PLAN2.md',
      projectRoot: '/mock/proj',
      type: 'generated-control',
      planName: undefined,
      overview: undefined,
      isProject: false,
      checkboxProgress: { completed: 0, total: 0 },
      currentTodo: undefined,
      lastActivityMs: Date.now() - 5000,
      hasLatestRun: false,
    },
  ],
  pageInfo: {
    hasMore: false,
    total: 2,
  },
  appliedFilters: {},
  counts: {
    total: 2,
    filtered: 2,
  },
};

const emptyPlanResponse: PlanInventoryResponse = {
  items: [],
  pageInfo: {
    hasMore: false,
    total: 0,
  },
  appliedFilters: { search: 'nonexistent' },
  counts: {
    total: 2,
    filtered: 0,
  },
};

function mountPlanHub(fixture: ComponentFixture<PlanHubComponent>): void {
  fixture.componentRef.setInput('paneActive', true);
  fixture.detectChanges();
}

function flushPlanIndex(
  httpMock: HttpTestingController,
  body: unknown,
  options?: { status?: number; statusText?: string },
): void {
  const pending = httpMock.match((r) => requestPath(r.url) === '/api/plans/index');
  const active = pending.filter((r) => !r.cancelled);
  expect(active.length).toBeGreaterThan(0);
  const req = active[active.length - 1];
  if (options?.status) {
    req.flush(body, { status: options.status, statusText: options.statusText ?? 'Error' });
  } else {
    req.flush(body);
  }
}

function flushAllPlanIndex(
  httpMock: HttpTestingController,
  body: unknown,
  options?: { status?: number; statusText?: string },
): void {
  const pending = httpMock.match((r) => requestPath(r.url) === '/api/plans/index');
  for (const req of pending) {
    if (req.cancelled) {
      continue;
    }
    if (options?.status) {
      req.flush(body, { status: options.status, statusText: options.statusText ?? 'Error' });
    } else {
      req.flush(body);
    }
  }
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
    httpMock.match(() => true).forEach((req) => {
      // Superseded requeries are cancelled by AbortSignal-based request cancellation.
      if (!req.cancelled) {
        req.flush(emptyPlanResponse);
      }
    });
    httpMock.verify();
  });

  it('fetches and displays plans from index API', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    const items = fixture.componentInstance.visibleItems();
    expect(items.length).toBe(2);
    expect(items[0].name).toBe('PLAN1');
    expect(items[1].name).toBe('PLAN2');
  });

  it('displays loading state initially', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    expect(fixture.componentInstance.loading()).toBe(true);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();
    tick();

    expect(fixture.componentInstance.loading()).toBe(false);
  }));

  it('displays error when plan index fails', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const comp = fixture.componentInstance;
    mountPlanHub(fixture);
    tick();
    flushPlanIndex(httpMock, mockPlanResponse);
    tick();
    fixture.detectChanges();

    comp.fetchPlans();
    flushPlanIndex(
      httpMock,
      {
        code: 'INTERNAL',
        message: 'Failed to load plans',
        title: 'Plans unavailable',
        explanation: 'The plan index could not be loaded.',
        recoverable: true,
        suggestedActions: ['RETRY'],
      },
      { status: 500, statusText: 'Error' },
    );
    tick();
    fixture.detectChanges();

    expect(comp.error()).toBeTruthy();
  }));

  it('displays empty state when no plans found', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, emptyPlanResponse);
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent;
    expect(text).toContain('No plans found');
  });

  it('clears search and filters from the empty-filter path', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    comp.queryState.set({ ...comp.queryState(), search: 'nope', status: 'active', type: 'leaf' });
    expect(comp.hasFilters()).toBe(true);
    comp.clearFilters();
    tick();
    fixture.detectChanges();

    expect(comp.queryState().search).toBe('');
    expect(comp.queryState().status).toBe('');
    expect(comp.queryState().type).toBe('');
    flushAllPlanIndex(httpMock, mockPlanResponse);
  }));

  it('debounces search input', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    fixture.componentInstance.onSearchChange('test');
    tick(100);
    fixture.detectChanges();

    fixture.componentInstance.onSearchChange('test search');
    tick(100);
    fixture.detectChanges();

    fixture.componentInstance.onSearchChange('test search query');
    tick(300);
    tick();
    fixture.detectChanges();

    const searchReq = httpMock.expectOne((r) => {
      const url = requestPath(r.url);
      return url === '/api/plans/index' && r.params.get('search') === 'test search query';
    });
    searchReq.flush(mockPlanResponse);
  }));

  it('filters by status when status filter changes', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    const currentQuery = comp.queryState();
    comp.queryState.set({ ...currentQuery, status: 'active' });
    comp.onStatusChange();
    tick();
    fixture.detectChanges();

    const searchReq = httpMock.expectOne((r) => {
      const url = requestPath(r.url);
      return url === '/api/plans/index' && r.params.get('status') === 'active';
    });
    searchReq.flush(mockPlanResponse);
  }));

  it('filters by type when type filter changes', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    const currentQuery = comp.queryState();
    comp.queryState.set({ ...currentQuery, type: 'leaf' });
    comp.onTypeChange();
    tick();
    fixture.detectChanges();

    const searchReq = httpMock.expectOne((r) => {
      const url = requestPath(r.url);
      return url === '/api/plans/index' && r.params.get('type') === 'leaf';
    });
    searchReq.flush(mockPlanResponse);
  }));

  it('changes sort field and order when column header clicked', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    comp.setSortField('name');
    fixture.detectChanges();

    expect(comp.queryState().sort).toBe('name');
    expect(comp.queryState().sortOrder).toBe('asc');

    comp.setSortField('name');
    fixture.detectChanges();

    expect(comp.queryState().sortOrder).toBe('desc');
  }));

  it('loads the next page when Next is selected', fakeAsync(() => {
    const manyItemsResponse: PlanInventoryResponse = {
      ...mockPlanResponse,
      pageInfo: {
        cursor: 'plan-2',
        hasMore: true,
        total: 50,
      },
    };

    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, manyItemsResponse);
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    expect(comp.pageInfo().hasMore).toBe(true);

    comp.nextPage();
    fixture.detectChanges();

    const nextReq = httpMock.expectOne((r) => {
      const url = requestPath(r.url);
      return url === '/api/plans/index' && r.params.get('cursor') === 'plan-2';
    });
    nextReq.flush(manyItemsResponse);
  }));

  it('navigates to the dedicated plan-detail route (not the generic file viewer) when row is clicked', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    const router = TestBed.inject(Router);
    const spy = vi.spyOn(router, 'navigate');

    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    const item = comp.visibleItems()[0];
    comp.onOpenPlan(item);

    expect(spy).toHaveBeenCalledWith(['/plan-detail', item.path], {
      queryParams: { projectRoot: item.projectRoot },
    });
  });

  it('renders plan list with correct columns', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent;
    expect(text).toContain('PLAN1');
    expect(text).toContain('PLAN2');
  });

  it('shows page controls when more results are available', () => {
    const manyItemsResponse: PlanInventoryResponse = {
      ...mockPlanResponse,
      pageInfo: {
        cursor: 'plan-2',
        hasMore: true,
        total: 50,
      },
    };

    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/plans/index');
    req.flush(manyItemsResponse);
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent;
    expect(text).toContain('Previous');
    expect(text).toContain('Next');
    expect(text).toContain('Page 1');
  });

  it('hides pagination button when hasMore is false', () => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent;
    expect(text).not.toContain('Previous');
  });

  it('clears cursor when filters change', fakeAsync(() => {
    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/plans/index');
    req.flush({ ...mockPlanResponse, pageInfo: { cursor: 'plan-2', hasMore: true, total: 50 } });
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    comp.nextPage();
    tick();
    expect(comp.queryState().cursor).toBe('plan-2');
    flushPlanIndex(httpMock, mockPlanResponse);
    tick();
    fixture.detectChanges();

    comp.onStatusChange();
    tick();
    fixture.detectChanges();

    expect(comp.queryState().cursor).toBeUndefined();
    flushPlanIndex(httpMock, mockPlanResponse);
  }));

  it('retains search in URL query parameters', fakeAsync(() => {
    const router = TestBed.inject(Router);
    const spy = vi.spyOn(router, 'navigate');

    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    comp.onSearchChange('test');
    tick(300);
    fixture.detectChanges();

    expect(spy).toHaveBeenCalledWith(
      [],
      expect.objectContaining({
        queryParams: expect.objectContaining({ search: 'test' }),
      })
    );
  }));

  it('retains status filter in URL query parameters', fakeAsync(() => {
    const router = TestBed.inject(Router);
    const spy = vi.spyOn(router, 'navigate');

    const fixture = TestBed.createComponent(PlanHubComponent);
    mountPlanHub(fixture);

    flushPlanIndex(httpMock, mockPlanResponse);
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    const currentQuery = comp.queryState();
    comp.queryState.set({ ...currentQuery, status: 'active' });
    comp.onStatusChange();
    fixture.detectChanges();

    expect(spy).toHaveBeenCalledWith(
      [],
      expect.objectContaining({
        queryParams: expect.objectContaining({ status: 'active' }),
      })
    );
  }));
});
