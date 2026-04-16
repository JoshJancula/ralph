import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed, fakeAsync, tick, flushMicrotasks } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { SidebarTreeComponent } from './sidebar-tree.component';
import { NavService } from '../../services/nav.service';

const testRoutes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: '**', redirectTo: 'plans' },
];

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

describe('SidebarTreeComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [SidebarTreeComponent, HttpClientTestingModule, RouterTestingModule.withRoutes(testRoutes)],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  function flushMicrotaskQueue() {
    tick(0);
  }

  function flushListing(
    root: string,
    path: string,
    entries: Array<{ name: string; path: string; type: 'file' | 'dir'; size: number; mtime: number }>,
  ): void {
    const req = httpMock.expectOne(
      (r) =>
        requestPath(r.url) === '/api/list' &&
        r.params.get('root') === root &&
        r.params.get('path') === path,
    );
    req.flush({
      root,
      path,
      parent: null,
      entries,
    });
  }

  it('renders directory entries as expandable rows', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.detectChanges();

    flushMicrotaskQueue();

    flushListing('logs', 'PLAN2', [
      { name: 'docs', path: 'PLAN2/docs/', type: 'dir', size: 0, mtime: 0 },
      { name: 'notes.md', path: 'PLAN2/notes.md', type: 'file', size: 1, mtime: 0 },
    ]);
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    // Check for toggle arrow on directory
    expect(el.textContent).toContain('docs');
    expect(el.textContent).toContain('notes.md');
    // Check that directory has toggle (▼ or ►)
    const treeRows = el.querySelectorAll('.tree-row');
    expect(treeRows.length).toBe(2);
  }));

  it('clicking a directory row calls fetchListing with the child path and renders children', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.detectChanges();

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [
      { name: 'docs', path: 'PLAN2/docs/', type: 'dir', size: 0, mtime: 0 },
    ]);
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    const dirRow = el.querySelectorAll('.tree-row')[0] as HTMLElement;
    
    // Click on the directory row to expand
    dirRow.click();
    flushMicrotaskQueue();

    flushListing('logs', 'PLAN2/docs/', [
      { name: 'nested.md', path: 'PLAN2/docs/nested.md', type: 'file', size: 1, mtime: 0 },
    ]);
    fixture.detectChanges();

    // After expansion, we should see both the directory and its child
    const allRows = el.querySelectorAll('.tree-row');
    expect(allRows.length).toBe(2);
    expect(el.textContent).toContain('nested.md');
  }));

  it('clicking a file row calls NavService.navigate with correct arguments', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.detectChanges();

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [
      { name: 'readme.md', path: 'PLAN2/readme.md', type: 'file', size: 1, mtime: 0 },
    ]);
    fixture.detectChanges();

    const rows = (fixture.nativeElement as HTMLElement).querySelectorAll('.tree-row');
    expect(rows.length).toBeGreaterThan(0);
    (rows[rows.length - 1] as HTMLElement).click();

    // Updated: now navigates with full path in the file parameter
    expect(spy).toHaveBeenCalledWith('logs', '', 'PLAN2/readme.md');
  }));

  it('highlights the active file', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    const nav = TestBed.inject(NavService);

    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.detectChanges();

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [
      { name: 'readme.md', path: 'PLAN2/readme.md', type: 'file', size: 1, mtime: 0 },
    ]);
    fixture.detectChanges();

    // Seed the active file directly so the selection logic can be asserted
    nav['activeFileSignal'].set('PLAN2/readme.md');
    fixture.detectChanges();

    const selected = (fixture.nativeElement as HTMLElement).querySelectorAll('.tree-row.selected');
    expect(selected.length).toBe(1);
    expect(selected[0].textContent).toContain('readme.md');
  }));

  it('shows loading indicator while fetch is in flight', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.detectChanges();

    flushMicrotaskQueue();

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('.loading-indicator')?.textContent?.trim()).toBe('Loading...');

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
    req.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [],
    });
    fixture.detectChanges();

    expect(el.querySelector('.loading-indicator')).toBeNull();
  }));

  it('cancels a pending directory fetch when the row is collapsed', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.detectChanges();

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [{ name: 'docs', path: 'PLAN2/docs/', type: 'dir', size: 0, mtime: 0 }]);
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    const dirRow = el.querySelectorAll('.tree-row')[0] as HTMLElement;

    dirRow.click();
    flushMicrotaskQueue();
    fixture.detectChanges();

    const pendingRequests = httpMock.match(
      (r) => requestPath(r.url) === '/api/list' && r.params.get('path') === 'PLAN2/docs/',
    );
    expect(pendingRequests.length).toBe(1);

    dirRow.click();
    flushMicrotaskQueue();
    fixture.detectChanges();

    const node = fixture.componentInstance.treeData()[0];
    expect(node.expanded).toBe(false);
    expect(node.loading).toBe(false);
    expect(el.querySelectorAll('.tree-row').length).toBe(1);

    pendingRequests[0].flush({
      root: 'logs',
      path: 'PLAN2/docs/',
      parent: 'PLAN2',
      entries: [
        { name: 'nested.md', path: 'PLAN2/docs/nested.md', type: 'file', size: 1, mtime: 0 },
      ],
    });
    fixture.detectChanges();

    expect(node.expanded).toBe(false);
    expect(node.loading).toBe(false);
    expect(el.querySelectorAll('.tree-row').length).toBe(1);
    expect(el.textContent).not.toContain('nested.md');
  }));

  it('clicking an expanded directory collapses children', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.detectChanges();

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [{ name: 'docs', path: 'PLAN2/docs/', type: 'dir', size: 0, mtime: 0 }]);
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    const dirRow = el.querySelectorAll('.tree-row')[0] as HTMLElement;

    // Expand by clicking the directory row
    dirRow.click();
    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2/docs/', [
      { name: 'nested.md', path: 'PLAN2/docs/nested.md', type: 'file', size: 1, mtime: 0 },
    ]);
    fixture.detectChanges();

    // Should have 2 rows now
    expect(el.querySelectorAll('.tree-row').length).toBe(2);

    // Collapse by clicking the directory row again
    const dirRowAfterExpand = el.querySelectorAll('.tree-row')[0] as HTMLElement;
    dirRowAfterExpand.click();
    tick();
    fixture.detectChanges();

    // Should be back to 1 row
    expect(el.querySelectorAll('.tree-row').length).toBe(1);
  }));

  it('failed child listing collapses the directory', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.detectChanges();

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [{ name: 'docs', path: 'PLAN2/docs/', type: 'dir', size: 0, mtime: 0 }]);
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    const dirRow = el.querySelectorAll('.tree-row')[0] as HTMLElement;

    // Click on the directory row to expand
    dirRow.click();
    flushMicrotaskQueue();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('path') === 'PLAN2/docs/');
    req.flush('err', { status: 500, statusText: 'Error' });
    fixture.detectChanges();

    const node = fixture.componentInstance.treeData()[0];
    expect(node.expanded).toBe(false);
    expect(node.loading).toBe(false);
  }));

  it('shows error message when fetchListing returns an error', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.detectChanges();

    flushMicrotaskQueue();
    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
    req.flush('fail', { status: 500, statusText: 'Internal Server Error' });
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('.error-message')?.textContent?.trim()).toBe('Failed to load directory listing');
  }));

  it('autoOpen opens first file when no active file', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.componentInstance.autoOpen = true;
    fixture.detectChanges();

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [
      { name: 'readme.md', path: 'PLAN2/readme.md', type: 'file', size: 1, mtime: 0 },
    ]);
    fixture.detectChanges();

    expect(spy).toHaveBeenCalledWith('logs', '', 'PLAN2/readme.md');
  }));

  it('autoOpen expands first directory when no files exist', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.componentInstance.autoOpen = true;
    fixture.detectChanges();

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [
      { name: 'docs', path: 'PLAN2/docs/', type: 'dir', size: 0, mtime: 0 },
    ]);
    fixture.detectChanges();

    // Should expand the directory and fetch its contents
    const childReq = httpMock.expectOne(
      (r) =>
        requestPath(r.url) === '/api/list' &&
        r.params.get('root') === 'logs' &&
        r.params.get('path') === 'PLAN2/docs/',
    );
    childReq.flush({
      root: 'logs',
      path: 'PLAN2/docs/',
      parent: 'PLAN2',
      entries: [
        { name: 'nested.md', path: 'PLAN2/docs/nested.md', type: 'file', size: 1, mtime: 0 },
      ],
    });
    fixture.detectChanges();

    // Should navigate to the first file found in subdirectory
    expect(spy).toHaveBeenCalledWith('logs', '', 'PLAN2/docs/nested.md');
  }));

  it('autoOpen does nothing when active file already exists', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    const nav = TestBed.inject(NavService);
    
    // Set up the component first
    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.componentInstance.autoOpen = true;
    fixture.detectChanges();

    // Seed the active file before data loads so autoOpen stays quiet
    nav['activeFileSignal'].set('PLAN2/readme.md');
    const spy = vi.spyOn(nav, 'navigate');

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [
      { name: 'readme.md', path: 'PLAN2/readme.md', type: 'file', size: 1, mtime: 0 },
    ]);
    fixture.detectChanges();

    // Should not navigate again since active file already exists
    expect(spy).not.toHaveBeenCalled();
  }));

  it('autoOpen does nothing when autoOpen is false', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.componentInstance.autoOpen = false;
    fixture.detectChanges();

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [
      { name: 'readme.md', path: 'PLAN2/readme.md', type: 'file', size: 1, mtime: 0 },
    ]);
    fixture.detectChanges();

    expect(spy).not.toHaveBeenCalled();
  }));

  it('ngOnInit does nothing when root is empty', fakeAsync(async () => {
    const fixture = TestBed.createComponent(SidebarTreeComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.componentInstance.root = '';
    fixture.componentInstance.path = '';
    fixture.componentInstance.autoOpen = true;
    fixture.detectChanges();

    flushMicrotaskQueue();

    // No API call should be made when root is empty
    expect(spy).not.toHaveBeenCalled();
  }));
});
