import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed, fakeAsync, tick, flush } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { WorkspaceSidebarComponent } from './workspace-sidebar.component';
import { NavService } from '../../services/nav.service';
import type { Root } from '../../services/api.service';

const testRoutes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: '**', redirectTo: 'plans' },
];

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

describe('WorkspaceSidebarComponent', () => {
  let httpMock: HttpTestingController;
  let originalScrollIntoView: typeof Element.prototype.scrollIntoView;

  beforeEach(async () => {
    // Mock scrollIntoView since it's not available in jsdom
    originalScrollIntoView = Element.prototype.scrollIntoView;
    Element.prototype.scrollIntoView = vi.fn();

    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [WorkspaceSidebarComponent, HttpClientTestingModule, RouterTestingModule.withRoutes(testRoutes)],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    // Restore original scrollIntoView before each test
    Element.prototype.scrollIntoView = originalScrollIntoView;
  });

  it('ngOnInit loads roots and isActive reflects NavService', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);

    fixture.detectChanges();
    tick();

    // Get the component's injected NavService - now initialized
    const nav = fixture.componentInstance['nav'];

    // Manually set the active root via the internal signal after initialization
    // This simulates what happens when user navigates to logs
    nav['activeRootSignal'].set('logs');

    // Handle the API call for roots
    const rootsReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    rootsReq.flush([
      { key: 'logs', label: 'Logs', exists: true },
      { key: 'plans', label: 'Plans', exists: true },
    ]);
    tick();

    // Flush any pending async operations
    flush();

    // Consume any pending HTTP requests from the sidebar-tree component
    httpMock.match(() => true).forEach((req) => {
      req.flush({
        root: 'logs',
        path: '',
        parent: null,
        entries: [],
      });
    });

    // Force change detection after async operations
    fixture.detectChanges();

    const logs: Root = { key: 'logs', label: 'Logs', exists: true };
    const plans: Root = { key: 'plans', label: 'Plans', exists: true };
    expect(fixture.componentInstance.roots()).toEqual([logs, plans]);
    // The logs root should be active since we set it after initialization
    expect(fixture.componentInstance.isActive(logs)).toBe(true);
    expect(fixture.componentInstance.isActive(plans)).toBe(false);
  }));

  it('selectRoot calls navigate with root key', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    // Seed the active root directly so the component starts in the expected state
    nav['activeRootSignal'].set('artifacts');

    fixture.detectChanges();
    tick(); // Allow ngOnInit to execute

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    req.flush([{ key: 'artifacts', label: 'Artifacts', exists: true }]);
    tick(); // Allow any follow-up to process

    // Flush any pending async operations and consume HTTP requests
    flush();
    httpMock.match(() => true).forEach((req) => {
      req.flush({
        root: 'artifacts',
        path: '',
        parent: null,
        entries: [],
      });
    });

    const root: Root = { key: 'artifacts', label: 'Artifacts', exists: true };
    fixture.componentInstance.selectRoot(root);
    // Should be called with 'artifacts' (was already called during setup)
    expect(spy).toHaveBeenCalledWith('artifacts');
  }));

  it('waits for the active-root lifecycle path before scrolling the selected root', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);
    const navigateSpy = vi.spyOn(nav, 'navigate').mockImplementation(() => {});
    const scrollSpy = vi.mocked(Element.prototype.scrollIntoView);

    nav['activeRootSignal'].set(null);

    fixture.detectChanges();
    tick();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    req.flush([{ key: 'logs', label: 'Logs', exists: true }]);
    tick();
    flush();
    httpMock.match(() => true).forEach((req) => {
      req.flush({
        root: 'logs',
        path: '',
        parent: null,
        entries: [],
      });
    });
    fixture.detectChanges();
    flush();

    scrollSpy.mockClear();

    const root: Root = { key: 'logs', label: 'Logs', exists: true };
    fixture.componentInstance.selectRoot(root);
    flush();

    expect(navigateSpy).toHaveBeenCalledWith('logs');
    expect(scrollSpy).not.toHaveBeenCalled();

    nav['activeRootSignal'].set('logs');
    fixture.detectChanges();
    flush();

    expect(scrollSpy).toHaveBeenCalledTimes(1);
    expect(scrollSpy).toHaveBeenCalledWith({ block: 'nearest' });
  }));

  it('toggleExpansion adds root to expanded set when not present', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);

    fixture.detectChanges();
    tick();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    req.flush([{ key: 'logs', label: 'Logs', exists: true }]);
    tick();
    flush();
    httpMock.match(() => true).forEach((req) => {
      req.flush({ root: 'logs', path: '', parent: null, entries: [] });
    });

    const logs: Root = { key: 'logs', label: 'Logs', exists: true };
    expect(fixture.componentInstance.isExpanded(logs)).toBe(false);

    fixture.componentInstance.toggleExpansion(logs);
    expect(fixture.componentInstance.isExpanded(logs)).toBe(true);
  }));

  it('toggleExpansion removes root from expanded set when present', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);

    fixture.detectChanges();
    tick();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    req.flush([{ key: 'logs', label: 'Logs', exists: true }]);
    tick();
    flush();
    httpMock.match(() => true).forEach((req) => {
      req.flush({ root: 'logs', path: '', parent: null, entries: [] });
    });

    const logs: Root = { key: 'logs', label: 'Logs', exists: true };
    fixture.componentInstance.toggleExpansion(logs);
    expect(fixture.componentInstance.isExpanded(logs)).toBe(true);

    fixture.componentInstance.toggleExpansion(logs);
    expect(fixture.componentInstance.isExpanded(logs)).toBe(false);
  }));

  it('toggleExpansion does nothing for non-existent roots', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);

    fixture.detectChanges();
    tick();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    req.flush([{ key: 'logs', label: 'Logs', exists: false }]);
    tick();
    flush();

    const logs: Root = { key: 'logs', label: 'Logs', exists: false };
    fixture.componentInstance.toggleExpansion(logs);
    expect(fixture.componentInstance.isExpanded(logs)).toBe(false);
  }));

  it('selectRoot does nothing for non-existent roots', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();
    tick();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    req.flush([{ key: 'logs', label: 'Logs', exists: false }]);
    tick();
    flush();

    const logs: Root = { key: 'logs', label: 'Logs', exists: false };
    fixture.componentInstance.selectRoot(logs);
    expect(spy).not.toHaveBeenCalled();
  }));

  it('selectRoot expands the root and clears user-collapsed state', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);

    fixture.detectChanges();
    tick();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    req.flush([{ key: 'logs', label: 'Logs', exists: true }]);
    tick();
    flush();
    httpMock.match(() => true).forEach((req) => {
      req.flush({ root: 'logs', path: '', parent: null, entries: [] });
    });

    const logs: Root = { key: 'logs', label: 'Logs', exists: true };
    fixture.componentInstance.toggleExpansion(logs);
    fixture.componentInstance.toggleExpansion(logs);
    expect(fixture.componentInstance.isExpanded(logs)).toBe(false);

    fixture.componentInstance.selectRoot(logs);
    expect(fixture.componentInstance.isExpanded(logs)).toBe(true);
  }));

  it('isActive returns true only for active root', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);

    fixture.detectChanges();
    tick();

    const navService = fixture.componentInstance['nav'] as any;
    navService.activeRootSignal.set('logs');

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    req.flush([
      { key: 'logs', label: 'Logs', exists: true },
      { key: 'plans', label: 'Plans', exists: true },
    ]);
    tick();
    flush();
    httpMock.match(() => true).forEach((req) => {
      req.flush({ root: 'logs', path: '', parent: null, entries: [] });
    });

    const logs: Root = { key: 'logs', label: 'Logs', exists: true };
    const plans: Root = { key: 'plans', label: 'Plans', exists: true };

    expect(fixture.componentInstance.isActive(logs)).toBe(true);
    expect(fixture.componentInstance.isActive(plans)).toBe(false);
  }));

});
