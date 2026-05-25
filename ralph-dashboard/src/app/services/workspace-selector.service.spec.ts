import '../../angular-test-env';
import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { vi } from 'vitest';

import { type WorkspaceRegistry } from './api.service';
import { WorkspaceSelectorService } from './workspace-selector.service';

function stubWorkspace(path: string, exists = true): WorkspaceRegistry {
  const segments = path.split('/');
  const label = segments[segments.length - 1] || path;
  return {
    path,
    workspaceRoot: `${path}/.ralph-workspace`,
    projectRoot: path,
    label,
    exists,
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
    reqs[0].flush([stubWorkspace('/a'), stubWorkspace('/b')]);
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
    req.flush([stubWorkspace('/only/one')]);
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
    req.flush([stubWorkspace('/a'), stubWorkspace('/b')]);
    tick();

    expect(service.isGlobalMode()).toBe(true);
    expect(service.shouldShowSwitcher()).toBe(true);
  }));

  it('clears selection when the registry becomes empty', fakeAsync(() => {
    const service = TestBed.inject(WorkspaceSelectorService);
    service.loadWorkspaces();
    let req = httpMock.expectOne('/api/workspaces');
    req.flush([stubWorkspace('/a')]);
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
    req.flush([stubWorkspace('/new')]);
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
    req.flush([stubWorkspace('/proj/foo'), stubWorkspace('/other')]);
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
    req.flush([stubWorkspace('single-segment'), stubWorkspace('/deleted', false)]);
    tick();

    const rows = service.displayWorkspaces();
    expect(rows).toHaveLength(1);
    expect(rows[0].exists).toBe(true);
    expect(rows[0].display).toBe('single-segment');
  }));
});
