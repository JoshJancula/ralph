import '../../../angular-test-env';
import { HttpClientTestingModule } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { ActivatedRoute } from '@angular/router';
import { of, throwError } from 'rxjs';
import { vi } from 'vitest';
import { PlanLogsComponent } from './plan-logs.component';
import { ApiService, ListingEntry } from '../../services/api.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { PlanLogResolutionService } from '../../services/plan-log-resolution.service';

describe('PlanLogsComponent', () => {
  function buildComponent(
    paramMap: Record<string, string>,
    queryParamMap: Record<string, string> = {},
    api: Partial<ApiService> = {},
    selected: string | null = null,
  ) {
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [PlanLogsComponent, HttpClientTestingModule],
      providers: [
        {
          provide: ActivatedRoute,
          useValue: {
            snapshot: {
              paramMap: { get: (key: string) => paramMap[key] ?? null },
              queryParamMap: { get: (key: string) => queryParamMap[key] ?? null },
            },
          },
        },
        { provide: ApiService, useValue: api },
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath: () => selected,
            selectWorkspace: vi.fn(),
            workspaces: () => [],
          },
        },
        {
          provide: PlanLogResolutionService,
          useValue: {
            resolveLatestLogTarget: vi.fn(() => of({ directory: null, file: null })),
          },
        },
      ],
    });
    return TestBed.createComponent(PlanLogsComponent);
  }

  it('shows empty state when no logs exist', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/proj' }, {
      fetchWorkspaces: vi.fn(() => of([
        { path: '/proj', workspaceRoot: '/proj/.ralph-workspace', projectRoot: '/proj', label: 'p', exists: true },
      ])),
      fetchListing: vi.fn(() => of({ root: 'logs', path: 'PLAN', parent: null, entries: [] })),
    });
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    expect(fixture.componentInstance.entries()).toEqual([]);
    expect(fixture.nativeElement.textContent).toContain('No logs have been recorded');
  });

  it('strips .md extension to derive plan key', async () => {
    const fixture = buildComponent({ file: 'plans/PLAN.md' }, { projectRoot: '/proj' }, {
      fetchWorkspaces: vi.fn(() => of([
        { path: '/proj', workspaceRoot: '/proj/.ralph-workspace', projectRoot: '/proj', label: 'p', exists: true },
      ])),
      fetchListing: vi.fn((_root, path) => of({
        root: 'logs', path, parent: null,
        entries: [{ name: 'output.log', path: `${path}/output.log`, type: 'file', size: 10, mtime: 1 } as ListingEntry],
      })),
    });
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    expect(fixture.componentInstance.entries()).toHaveLength(1);
    expect(fixture.componentInstance.entries()[0].name).toBe('output.log');
  });

  it('filters out directories and keeps only files', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/proj' }, {
      fetchWorkspaces: vi.fn(() => of([
        { path: '/proj', workspaceRoot: '/proj/.ralph-workspace', projectRoot: '/proj', label: 'p', exists: true },
      ])),
      fetchListing: vi.fn(() => of({
        root: 'logs', path: 'PLAN', parent: null,
        entries: [
          { name: 'run-1', path: 'PLAN/run-1', type: 'dir', size: 0, mtime: 1 },
          { name: 'output.log', path: 'PLAN/output.log', type: 'file', size: 10, mtime: 1 },
        ],
      })),
    });
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    expect(fixture.componentInstance.entries()).toHaveLength(1);
    expect(fixture.componentInstance.entries()[0].type).toBe('file');
  });

  it('does not fall back to the first workspace when projectRoot is missing', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, {}, {
      fetchWorkspaces: vi.fn(() => of([
        { path: '/global', workspaceRoot: '/global/.ralph-workspace', projectRoot: '/global', label: 'g', exists: true },
        { path: '/proj', workspaceRoot: '/proj/.ralph-workspace', projectRoot: '/proj', label: 'p', exists: true },
      ])),
      fetchListing: vi.fn(),
    });
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    const err = fixture.componentInstance.error();
    expect(err).toBeInstanceOf(Error);
    expect(String((err as Error).message)).toContain('Select a project');
    expect(fixture.componentInstance.loading()).toBe(false);
  });

  it('shows error when workspace lookup fails', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/missing' }, {
      fetchWorkspaces: vi.fn(() => of([
        { path: '/proj', workspaceRoot: '/proj/.ralph-workspace', projectRoot: '/proj', label: 'p', exists: true },
      ])),
    });
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    const err = fixture.componentInstance.error();
    expect(err).toBeInstanceOf(Error);
    expect(String((err as Error).message)).toContain('plan workspace is unavailable');
    expect(fixture.componentInstance.loading()).toBe(false);
  });

  it('shows error when listing fails', async () => {
    const fixture = buildComponent({ file: 'PLAN.md' }, { projectRoot: '/proj' }, {
      fetchWorkspaces: vi.fn(() => of([
        { path: '/proj', workspaceRoot: '/proj/.ralph-workspace', projectRoot: '/proj', label: 'p', exists: true },
      ])),
      fetchListing: vi.fn(() => throwError(() => new Error('fail'))),
    });
    await fixture.componentInstance.ngOnInit();
    fixture.detectChanges();

    const err = fixture.componentInstance.error();
    expect(err).toBeInstanceOf(Error);
    expect(String((err as Error).message)).toContain('fail');
    expect(fixture.componentInstance.loading()).toBe(false);
  });

  it('selects the matching workspace when the selector is out of sync', async () => {
    const selectWorkspace = vi.fn();
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [PlanLogsComponent, HttpClientTestingModule],
      providers: [
        {
          provide: ActivatedRoute,
          useValue: {
            snapshot: {
              paramMap: { get: (key: string) => (key === 'file' ? 'PLAN.md' : null) },
              queryParamMap: { get: (key: string) => (key === 'projectRoot' ? '/proj' : null) },
            },
          },
        },
        {
          provide: ApiService,
          useValue: {
            fetchWorkspaces: vi.fn(() =>
              of([
                {
                  path: '/proj',
                  workspaceRoot: '/proj/.ralph-workspace',
                  projectRoot: '/proj/',
                  label: 'p',
                  exists: true,
                },
              ]),
            ),
            fetchListing: vi.fn(() =>
              of({
                root: 'logs',
                path: 'PLAN',
                parent: null,
                entries: [{ name: 'a.log', path: 'PLAN/a.log', type: 'file', size: 1, mtime: 2 }],
              }),
            ),
          },
        },
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath: () => '/other',
            selectWorkspace,
            workspaces: () => [],
          },
        },
        {
          provide: PlanLogResolutionService,
          useValue: { resolveLatestLogTarget: vi.fn(() => of({ directory: null, file: null })) },
        },
      ],
    });
    const fixture = TestBed.createComponent(PlanLogsComponent);
    await fixture.componentInstance.ngOnInit();
    expect(selectWorkspace).toHaveBeenCalledWith('/proj/');
    expect(fixture.componentInstance.workspaceRoot()).toBe('/proj/.ralph-workspace');
  });

  it('resolves workspace from the selected project when query projectRoot is absent', async () => {
    const fixture = buildComponent(
      { file: 'PLAN.md' },
      {},
      {
        fetchWorkspaces: vi.fn(() =>
          of([
            {
              path: '/proj',
              workspaceRoot: '/proj/.ralph-workspace',
              projectRoot: '/proj',
              label: 'p',
              exists: true,
            },
          ]),
        ),
        fetchListing: vi.fn(() => of({ root: 'logs', path: 'PLAN', parent: null, entries: [] })),
      },
      '/proj',
    );
    await fixture.componentInstance.ngOnInit();
    expect(fixture.componentInstance.error()).toBeNull();
    expect(fixture.componentInstance.workspaceRoot()).toBe('/proj/.ralph-workspace');
  });

  it('uses resolved latest nested log when the listing has only directories', async () => {
    const resolveLatestLogTarget = vi.fn(() => of({ directory: 'PLAN/run-1', file: 'PLAN/run-1/output.log' }));
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [PlanLogsComponent, HttpClientTestingModule],
      providers: [
        {
          provide: ActivatedRoute,
          useValue: {
            snapshot: {
              paramMap: { get: (key: string) => (key === 'file' ? 'PLAN.md' : null) },
              queryParamMap: { get: (key: string) => (key === 'projectRoot' ? '/proj' : null) },
            },
          },
        },
        {
          provide: ApiService,
          useValue: {
            fetchWorkspaces: vi.fn(() =>
              of([
                {
                  path: '/proj',
                  workspaceRoot: '/proj/.ralph-workspace',
                  projectRoot: '/proj',
                  label: 'p',
                  exists: true,
                },
              ]),
            ),
            fetchListing: vi.fn(() =>
              of({
                root: 'logs',
                path: 'PLAN',
                parent: null,
                entries: [{ name: 'run-1', path: 'PLAN/run-1', type: 'dir', size: 0, mtime: 9 }],
              }),
            ),
          },
        },
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath: () => '/proj',
            selectWorkspace: vi.fn(),
            workspaces: () => [],
          },
        },
        { provide: PlanLogResolutionService, useValue: { resolveLatestLogTarget } },
      ],
    });
    const fixture = TestBed.createComponent(PlanLogsComponent);
    await fixture.componentInstance.ngOnInit();
    expect(resolveLatestLogTarget).toHaveBeenCalled();
    expect(fixture.componentInstance.entries()[0]?.path).toBe('PLAN/run-1/output.log');
  });

  it('walks nested dirs and skips unreadable children when no latest file is resolved', async () => {
    let listingCalls = 0;
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [PlanLogsComponent, HttpClientTestingModule],
      providers: [
        {
          provide: ActivatedRoute,
          useValue: {
            snapshot: {
              paramMap: { get: (key: string) => (key === 'file' ? 'PLAN.md' : null) },
              queryParamMap: { get: (key: string) => (key === 'projectRoot' ? '/proj' : null) },
            },
          },
        },
        {
          provide: ApiService,
          useValue: {
            fetchWorkspaces: vi.fn(() =>
              of([
                {
                  path: '/proj',
                  workspaceRoot: '/proj/.ralph-workspace',
                  projectRoot: '/proj',
                  label: 'p',
                  exists: true,
                },
              ]),
            ),
            fetchListing: vi.fn((_root: string, path: string) => {
              listingCalls += 1;
              if (path === 'PLAN' || path === 'PLAN.md' || !path.includes('/')) {
                return of({
                  root: 'logs',
                  path: 'PLAN',
                  parent: null,
                  entries: [
                    { name: 'bad', path: 'PLAN/bad', type: 'dir', size: 0, mtime: 3 },
                    { name: 'good', path: 'PLAN/good', type: 'dir', size: 0, mtime: 2 },
                  ],
                });
              }
              if (path === 'PLAN/bad') {
                return throwError(() => new Error('denied'));
              }
              return of({
                root: 'logs',
                path,
                parent: null,
                entries: [{ name: 'nested.log', path: `${path}/nested.log`, type: 'file', size: 4, mtime: 8 }],
              });
            }),
          },
        },
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath: () => '/proj',
            selectWorkspace: vi.fn(),
            workspaces: () => [],
          },
        },
        {
          provide: PlanLogResolutionService,
          useValue: { resolveLatestLogTarget: vi.fn(() => of({ directory: null, file: null })) },
        },
      ],
    });
    const fixture = TestBed.createComponent(PlanLogsComponent);
    await fixture.componentInstance.ngOnInit();
    expect(listingCalls).toBeGreaterThan(1);
    expect(fixture.componentInstance.entries().map((e) => e.name)).toEqual(['nested.log']);
  });
});
