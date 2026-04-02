import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed, fakeAsync, tick, flushMicrotasks } from '@angular/core/testing';
import { SidebarTreeComponent } from './sidebar-tree.component';
import { NavService } from '../../services/nav.service';

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

describe('SidebarTreeComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    window.location.hash = '';
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [SidebarTreeComponent, HttpClientTestingModule],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
    window.location.hash = '';
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
    
    // Click on the expander (+/-) specifically
    const toggle = dirRow.querySelector('.tree-expander') as HTMLElement;
    expect(toggle).toBeTruthy();
    toggle.click();
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
    nav.navigate('logs', '', 'PLAN2/readme.md');

    fixture.componentInstance.root = 'logs';
    fixture.componentInstance.path = 'PLAN2';
    fixture.detectChanges();

    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2', [
      { name: 'readme.md', path: 'PLAN2/readme.md', type: 'file', size: 1, mtime: 0 },
    ]);
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
    const toggle = dirRow.querySelector('.tree-expander') as HTMLElement;
    
    // Expand
    toggle.click();
    flushMicrotaskQueue();
    flushListing('logs', 'PLAN2/docs/', [
      { name: 'nested.md', path: 'PLAN2/docs/nested.md', type: 'file', size: 1, mtime: 0 },
    ]);
    fixture.detectChanges();

    // Should have 2 rows now
    expect(el.querySelectorAll('.tree-row').length).toBe(2);

    // Collapse
    toggle.click();
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
    const toggle = dirRow.querySelector('.tree-expander') as HTMLElement;
    toggle.click();
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
});
