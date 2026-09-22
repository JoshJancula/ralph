import '../../../angular-test-env';
import { HttpClientTestingModule } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { of, throwError } from 'rxjs';
import { DocsHubComponent } from './docs-hub.component';
import { ApiService, ListingEntry } from '../../services/api.service';
import { vi } from 'vitest';

describe('DocsHubComponent', () => {
  function mockApi(frameworkRoot?: string, dashboardRoot?: string, listings: Record<string, ListingEntry[]> = {}) {
    return {
      fetchRalphFrameworkProjectRoot: vi.fn(() => of({ projectRoot: frameworkRoot })),
      fetchDashboardDocsProjectRoot: vi.fn(() => of({ projectRoot: dashboardRoot })),
      fetchListing: vi.fn((_root: string, path: string, _workspaceRoot?: string, projectRoot?: string) => {
        const key = `${projectRoot}:${path}`;
        return of({ root: 'docs', path, parent: null, entries: listings[key] ?? [] });
      }),
    };
  }

  beforeEach(() => {
    TestBed.resetTestingModule();
  });

  function setup(frameworkRoot?: string, dashboardRoot?: string, listings: Record<string, ListingEntry[]> = {}) {
    TestBed.configureTestingModule({
      imports: [DocsHubComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
      providers: [{ provide: ApiService, useValue: mockApi(frameworkRoot, dashboardRoot, listings) }],
    });
    return TestBed.createComponent(DocsHubComponent);
  }

  it('renders empty state when no documentation roots are available', async () => {
    const fixture = setup();
    await fixture.componentInstance.loadDocs();

    expect(fixture.componentInstance.docs()).toEqual([]);
    expect(fixture.componentInstance.error()).toBeNull();
    expect(fixture.componentInstance.loading()).toBe(false);
  });

  it('renders docs from the framework root', async () => {
    const listings: Record<string, ListingEntry[]> = {
      '/ralph:': [
        { name: 'README.md', path: 'README.md', type: 'file', size: 10, mtime: 1 },
        { name: 'GUIDE.mdx', path: 'GUIDE.mdx', type: 'file', size: 10, mtime: 1 },
        { name: 'note.txt', path: 'note.txt', type: 'file', size: 10, mtime: 1 },
        { name: 'skipped', path: 'skipped', type: 'file', size: 10, mtime: 1 },
      ],
    };
    const fixture = setup('/ralph', undefined, listings);
    await fixture.componentInstance.loadDocs();
    fixture.detectChanges();

    const docs = fixture.componentInstance.docs();
    expect(docs).toHaveLength(3);
    expect(docs[0].name).toBe('GUIDE.mdx');
    expect(docs[0].source).toBe('Ralph CLI');
  });

  it('recursively collects docs from subdirectories', async () => {
    const listings: Record<string, ListingEntry[]> = {
      '/ralph:': [{ name: 'nested', path: 'nested', type: 'dir', size: 0, mtime: 1 }],
      '/ralph:nested': [{ name: 'DEEP.md', path: 'nested/DEEP.md', type: 'file', size: 10, mtime: 1 }],
    };
    const fixture = setup('/ralph', undefined, listings);
    await fixture.componentInstance.loadDocs();
    fixture.detectChanges();

    expect(fixture.componentInstance.docs()).toHaveLength(1);
    expect(fixture.componentInstance.docs()[0].path).toBe('nested/DEEP.md');
  });

  it('combines framework and dashboard sources', async () => {
    const listings: Record<string, ListingEntry[]> = {
      '/ralph:': [{ name: 'A.md', path: 'A.md', type: 'file', size: 10, mtime: 1 }],
      '/dash:': [{ name: 'B.md', path: 'B.md', type: 'file', size: 10, mtime: 1 }],
    };
    const fixture = setup('/ralph', '/dash', listings);
    await fixture.componentInstance.loadDocs();
    fixture.detectChanges();

    expect(fixture.componentInstance.docs()).toHaveLength(2);
    expect(fixture.componentInstance.docs().map(d => d.source)).toContain('Ralph Dashboard');
    expect(fixture.componentInstance.docs().map(d => d.source)).toContain('Ralph CLI');
    expect(fixture.componentInstance.cliDocs()).toHaveLength(1);
    expect(fixture.componentInstance.dashboardDocs()).toHaveLength(1);
  });

  it('shows error when listing throws', async () => {
    TestBed.configureTestingModule({
      imports: [DocsHubComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
      providers: [
        {
          provide: ApiService,
          useValue: {
            fetchRalphFrameworkProjectRoot: vi.fn(() => of({ projectRoot: '/ralph' })),
            fetchDashboardDocsProjectRoot: vi.fn(() => of({ projectRoot: undefined })),
            fetchListing: vi.fn(() => throwError(() => new Error('fail'))),
          },
        },
      ],
    });
    const fixture = TestBed.createComponent(DocsHubComponent);
    await fixture.componentInstance.loadDocs();

    expect(fixture.componentInstance.error()).toBeTruthy();
    expect(fixture.componentInstance.loading()).toBe(false);
    fixture.detectChanges();
  });
});
