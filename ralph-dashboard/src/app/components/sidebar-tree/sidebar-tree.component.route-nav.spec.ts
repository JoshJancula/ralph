/**
 * Regression tests for sidebar tree component with route-driven navigation.
 */
import { Component } from '@angular/core';
import { Routes } from '@angular/router';

import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { SidebarTreeComponent } from './sidebar-tree.component';
import { NavService } from '../../services/nav.service';

/**
 * Dummy router outlet component that satisfies Angular's route validation.
 */
@Component({
  selector: 'app-dummy-outlet',
  standalone: true,
  template: '',
})
class DummyOutletComponent {}

/**
 * Test routes that accept any URL pattern.
 */
const testRoutes: Routes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: '**', component: DummyOutletComponent },
];

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

describe('SidebarTreeComponent - Route-Driven Navigation', () => {
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

  describe('Tree loading behavior', () => {
    it('shows loading indicator while fetch is in flight', fakeAsync(async () => {
      const fixture = TestBed.createComponent(SidebarTreeComponent);
      fixture.componentInstance.root = 'logs';
      fixture.componentInstance.path = 'PLAN2';
      fixture.detectChanges();

      tick(0);

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

    it('renders directory entries as expandable rows', fakeAsync(async () => {
      const fixture = TestBed.createComponent(SidebarTreeComponent);
      fixture.componentInstance.root = 'logs';
      fixture.componentInstance.path = 'PLAN2';
      fixture.detectChanges();

      tick(0);

      const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
      req.flush({
        root: 'logs',
        path: 'PLAN2',
        parent: null,
        entries: [
          { name: 'docs', path: 'PLAN2/docs/', type: 'dir', size: 0, mtime: 0 },
          { name: 'notes.md', path: 'PLAN2/notes.md', type: 'file', size: 1, mtime: 0 },
        ],
      });
      fixture.detectChanges();

      const el = fixture.nativeElement as HTMLElement;
      expect(el.textContent).toContain('docs');
      expect(el.textContent).toContain('notes.md');
      const treeRows = el.querySelectorAll('.tree-row');
      expect(treeRows.length).toBe(2);
    }));
  });

  describe('Navigation via tree clicks', () => {
    it('clicking a file row calls NavService.navigate with correct arguments', fakeAsync(async () => {
      const fixture = TestBed.createComponent(SidebarTreeComponent);
      const nav = TestBed.inject(NavService);
      const spy = vi.spyOn(nav, 'navigate');

      fixture.componentInstance.root = 'logs';
      fixture.componentInstance.path = 'PLAN2';
      fixture.detectChanges();

      tick(0);
      const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
      req.flush({
        root: 'logs',
        path: 'PLAN2',
        parent: null,
        entries: [
          { name: 'readme.md', path: 'PLAN2/readme.md', type: 'file', size: 1, mtime: 0 },
        ],
      });
      fixture.detectChanges();

      const rows = (fixture.nativeElement as HTMLElement).querySelectorAll('.tree-row');
      expect(rows.length).toBeGreaterThan(0);
      (rows[rows.length - 1] as HTMLElement).click();

      // Updated: now navigates with full path in the file parameter
      expect(spy).toHaveBeenCalledWith('logs', '', 'PLAN2/readme.md');
    }));

    it('clicking directory row expands children', fakeAsync(async () => {
      const fixture = TestBed.createComponent(SidebarTreeComponent);
      fixture.componentInstance.root = 'logs';
      fixture.componentInstance.path = 'PLAN2';
      fixture.detectChanges();

      tick(0);
      const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
      req.flush({
        root: 'logs',
        path: 'PLAN2',
        parent: null,
        entries: [
          { name: 'docs', path: 'PLAN2/docs/', type: 'dir', size: 0, mtime: 0 },
        ],
      });
      fixture.detectChanges();

      const el = fixture.nativeElement as HTMLElement;
      const dirRow = el.querySelectorAll('.tree-row')[0] as HTMLElement;

      // Click on the expander (+/-) specifically
      const toggle = dirRow.querySelector('.tree-expander') as HTMLElement;
      expect(toggle).toBeTruthy();
      toggle.click();
      tick(0);

      const childReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('path') === 'PLAN2/docs/');
      childReq.flush({
        root: 'logs',
        path: 'PLAN2/docs/',
        parent: 'PLAN2',
        entries: [
          { name: 'nested.md', path: 'PLAN2/docs/nested.md', type: 'file', size: 1, mtime: 0 },
        ],
      });
      fixture.detectChanges();

      // After expansion, we should see both the directory and its child
      const allRows = el.querySelectorAll('.tree-row');
      expect(allRows.length).toBe(2);
      expect(el.textContent).toContain('nested.md');
    }));
  });

  describe('Error handling for missing assets', () => {
    it('shows error message when fetchListing returns an error', fakeAsync(async () => {
      const fixture = TestBed.createComponent(SidebarTreeComponent);
      fixture.componentInstance.root = 'logs';
      fixture.componentInstance.path = 'PLAN2';
      fixture.detectChanges();

      tick(0);
      const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
      req.flush('fail', { status: 500, statusText: 'Internal Server Error' });
      fixture.detectChanges();

      const el = fixture.nativeElement as HTMLElement;
      expect(el.querySelector('.error-message')?.textContent?.trim()).toBe('Failed to load directory listing');
    }));

    it('failed child listing collapses the directory', fakeAsync(async () => {
      const fixture = TestBed.createComponent(SidebarTreeComponent);
      fixture.componentInstance.root = 'logs';
      fixture.componentInstance.path = 'PLAN2';
      fixture.detectChanges();

      tick(0);
      const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/list');
      req.flush({
        root: 'logs',
        path: 'PLAN2',
        parent: null,
        entries: [
          { name: 'docs', path: 'PLAN2/docs/', type: 'dir', size: 0, mtime: 0 },
        ],
      });
      fixture.detectChanges();

      const el = fixture.nativeElement as HTMLElement;
      const dirRow = el.querySelectorAll('.tree-row')[0] as HTMLElement;
      const toggle = dirRow.querySelector('.tree-expander') as HTMLElement;
      toggle.click();
      tick(0);

      const childReq = httpMock.expectOne((r) => requestPath(r.url) === '/api/list' && r.params.get('path') === 'PLAN2/docs/');
      childReq.flush('err', { status: 500, statusText: 'Error' });
      fixture.detectChanges();

      const node = fixture.componentInstance.treeData()[0];
      expect(node.expanded).toBe(false);
      expect(node.loading).toBe(false);
    }));
  });
});