import '../../angular-test-env';
import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { vi } from 'vitest';

import { type WorkspaceRegistry } from './api.service';
import { WorkspaceSelectorService } from './workspace-selector.service';

function stubWorkspace(
  path: string,
  projectRoot: string,
  exists = true,
  lastSeen?: string
): WorkspaceRegistry {
  const segments = path.split('/');
  const label = segments[segments.length - 1] || path;
  return {
    path,
    workspaceRoot: `${path}/.ralph-workspace`,
    projectRoot,
    label,
    exists,
    lastSeen,
  };
}

describe('WorkspaceSelectorService', () => {
  let httpMock: HttpTestingController;
  const key = 'ralph-workspace-selected';

  beforeEach(() => {
    localStorage.clear();
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
    });
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
    localStorage.clear();
  });

  it('coalesces concurrent loadWorkspaces calls into one HTTP request', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    const cb1 = vi.fn();
    const cb2 = vi.fn();
    service.loadWorkspaces(cb1);
    service.loadWorkspaces(cb2);
    const reqs = httpMock.match('/api/workspaces');
    expect(reqs.length).toBe(1);
    reqs[0].flush([
      stubWorkspace('/a', '/a'),
      stubWorkspace('/b', '/b'),
    ]);
    tick();

    expect(cb1).toHaveBeenCalledTimes(1);
    expect(cb2).toHaveBeenCalledTimes(1);
    expect(service.workspaces().length).toBe(2);
  }));

  it('loadWorkspaces populates workspaces and auto-selects when a single entry', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    expect(service.selectedWorkspacePath()).toBeNull();

    service.loadWorkspaces();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([stubWorkspace('/only/one', '/only/one')]);
    tick();

    expect(service.workspaces().length).toBe(1);
    expect(service.selectedWorkspacePath()).toBe('/only/one');
    expect(service.isGlobalMode()).toBe(false);
    expect(service.shouldShowSwitcher()).toBe(false);
    expect(service.displayWorkspaces()[0].display).toBe('one');
  }));

  it('shows switcher in global mode with two or more workspaces', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.loadWorkspaces();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/a', '/a'),
      stubWorkspace('/b', '/b'),
    ]);
    tick();

    expect(service.isGlobalMode()).toBe(true);
    expect(service.shouldShowSwitcher()).toBe(true);
  }));

  it('clears selection when the registry becomes empty', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.loadWorkspaces();
    let req = httpMock.expectOne('/api/workspaces');
    req.flush([stubWorkspace('/a', '/a')]);
    tick();
    expect(service.selectedWorkspacePath()).toBe('/a');

    service.loadWorkspaces();
    req = httpMock.expectOne('/api/workspaces');
    req.flush([]);
    tick();

    expect(service.workspaces().length).toBe(0);
    expect(service.selectedWorkspacePath()).toBeNull();
  }));

  it('clears selection when the selected path is no longer listed', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.selectWorkspace('/old');
    expect(localStorage.getItem(key)).toBe('/old');

    service.loadWorkspaces();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([stubWorkspace('/new', '/new')]);
    tick();

    expect(service.selectedWorkspacePath()).toBeNull();
    expect(localStorage.getItem(key)).toBeNull();
  }));

  it('selectWorkspace null clears storage, non-null persists', () => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.selectWorkspace('/p');
    expect(localStorage.getItem(key)).toBe('/p');
    service.selectWorkspace(null);
    expect(localStorage.getItem(key)).toBeNull();
  });

  it('getWorkspaceForMetricPath returns the matching workspace path', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.loadWorkspaces();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/proj/foo', '/proj/foo'),
      stubWorkspace('/other', '/other'),
    ]);
    tick();

    expect(service.getWorkspaceForMetricPath('/proj/foo/.ralph-workspace/logs/x')).toBe(
      '/proj/foo',
    );
    expect(service.getWorkspaceForMetricPath('/none')).toBeNull();
  }));

  it('filters missing entries and uses basename for display names', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.loadWorkspaces();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('single-segment', 'single-segment'),
      stubWorkspace('/deleted', '/deleted', false),
    ]);
    tick();

    const rows = service.displayWorkspaces();
    expect(rows).toHaveLength(1);
    expect(rows[0].exists).toBe(true);
    expect(rows[0].display).toBe('single-segment');
  }));

  it('tracks and persists pinned projects', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.loadWorkspaces();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/p1', '/p1'),
      stubWorkspace('/p2', '/p2'),
    ]);
    tick();

    service.togglePinnedProject('/p1');
    expect(service.isPinnedProject('/p1')).toBe(true);
    expect(service.isPinnedProject('/p2')).toBe(false);

    const stored = localStorage.getItem('ralph-pinned-projects');
    expect(stored).toBeTruthy();
    expect(JSON.parse(stored!)).toContain('/p1');

    service.togglePinnedProject('/p1');
    expect(service.isPinnedProject('/p1')).toBe(false);
  }));

  it('tracks and persists recent projects', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.loadWorkspaces();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/p1', '/p1'),
      stubWorkspace('/p2', '/p2'),
      stubWorkspace('/p3', '/p3'),
    ]);
    tick();

    service.selectWorkspace('/p1');
    service.selectWorkspace('/p2');

    const stored = localStorage.getItem('ralph-recent-projects');
    expect(stored).toBeTruthy();
    const recent = JSON.parse(stored!);
    expect(recent[0]).toBe('/p2');
    expect(recent[1]).toBe('/p1');
  }));

  it('groups projects into pinned, recent, and all', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.loadWorkspaces();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/p1', '/p1'),
      stubWorkspace('/p2', '/p2'),
      stubWorkspace('/p3', '/p3'),
    ]);
    tick();

    service.togglePinnedProject('/p1');
    service.selectWorkspace('/p2');

    const groups = service.groupedProjects();
    expect(groups.length).toBeGreaterThan(0);
    const labels = groups.map((g) => g.label);
    expect(labels).toContain('Pinned');
    expect(labels).toContain('Recent');
    expect(labels).toContain('All projects');
  }));

  it('detects duplicate names', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.loadWorkspaces();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/path/one/app', '/path/one/app', true, 'app'),
      stubWorkspace('/path/two/app', '/path/two/app', true, 'app'),
    ]);
    tick();

    expect(service.getHasDuplicateNames()).toBe(true);
  }));

  it('provides parent path for disambiguation', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.loadWorkspaces();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/projects/myapp', '/projects/myapp'),
      stubWorkspace('/archive/myapp', '/archive/myapp'),
    ]);
    tick();

    const groups = service.groupedProjects();
    const allGroup = groups.find((g) => g.label === 'All projects');
    expect(allGroup).toBeTruthy();
    const items = allGroup!.projects;
    expect(items.some((p) => p.parentPath === '/projects')).toBe(true);
    expect(items.some((p) => p.parentPath === '/archive')).toBe(true);
  }));
});
