import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed, fakeAsync, tick, flush } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { WorkspaceSidebarComponent } from './workspace-sidebar.component';
import { NavService } from '../../services/nav.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import type { Root, WorkspaceRegistry } from '../../services/api.service';

const testRoutes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: '**', redirectTo: 'plans' },
];

const allSections = {
  logs: true,
  artifacts: true,
  sessions: true,
  'orchestration-plans': true,
  docs: true,
  plans: true,
};

function workspace(path: string, sections: Record<string, boolean> = allSections): WorkspaceRegistry {
  return {
    path,
    workspaceRoot: `${path}/.ralph-workspace`,
    projectRoot: path,
    label: path.split('/').pop() || path,
    exists: true,
    sections,
  };
}

function flushSidebarBootstrap(
  httpMock: HttpTestingController,
  roots: Root[],
  options: { projectRoot?: string; workspaces?: unknown[] } = {},
): void {
  const projectRoot = options.projectRoot ?? '/mock/project';
  const workspaces = options.workspaces ?? [];
  let workspaceDone = false;
  let workspacesDone = false;
  let rootsDone = false;

  for (let attempt = 0; attempt < 30; attempt++) {
    if (workspaceDone && workspacesDone && rootsDone) {
      return;
    }
    let progressed = false;

    if (!workspaceDone) {
      try {
        httpMock
          .expectOne((r) => r.url.includes('/api/workspace') && !r.url.includes('/api/workspaces'))
          .flush({ root: projectRoot });
        workspaceDone = true;
        progressed = true;
        continue;
      } catch {
        // try other types this round
      }
    }

    if (!workspacesDone) {
      const batch = httpMock.match((r) => r.url.includes('/api/workspaces'));
      if (batch.length > 0) {
        for (const q of batch) {
          q.flush(workspaces);
        }
        workspacesDone = true;
        progressed = true;
        continue;
      }
    }

    if (!rootsDone) {
      try {
        httpMock.expectOne((r) => r.url.includes('/api/roots')).flush(roots);
        rootsDone = true;
        progressed = true;
        continue;
      } catch {
        // no-op
      }
    }

    if (!progressed) {
      break;
    }
  }

  expect(workspaceDone && workspacesDone && rootsDone).toBe(true);
}

describe('WorkspaceSidebarComponent', () => {
  let httpMock: HttpTestingController;
  let originalScrollIntoView: typeof Element.prototype.scrollIntoView;

  beforeEach(async () => {
    originalScrollIntoView = Element.prototype.scrollIntoView;
    Element.prototype.scrollIntoView = vi.fn();

    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [WorkspaceSidebarComponent, HttpClientTestingModule, RouterTestingModule.withRoutes(testRoutes)],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    Element.prototype.scrollIntoView = originalScrollIntoView;
  });

  it('ngOnInit loads roots and isActive reflects NavService', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);

    fixture.detectChanges();
    tick();

    const nav = fixture.componentInstance['nav'];

    nav['activeRootSignal'].set('logs');

    flushSidebarBootstrap(httpMock, [
      { key: 'logs', label: 'Logs', exists: true },
      { key: 'plans', label: 'Plans', exists: true },
    ]);
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

    const logs: Root = { key: 'logs', label: 'Logs', exists: true };
    const plans: Root = { key: 'plans', label: 'Plans', exists: true };
    expect(fixture.componentInstance.roots()).toEqual([logs, plans]);
    expect(fixture.componentInstance.isActive(logs)).toBe(true);
    expect(fixture.componentInstance.isActive(plans)).toBe(false);
  }));

  it('selectRoot calls navigate with root key', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    nav['activeRootSignal'].set('artifacts');

    fixture.detectChanges();
    tick();

    flushSidebarBootstrap(httpMock, [{ key: 'artifacts', label: 'Artifacts', exists: true }]);
    tick();

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

    flushSidebarBootstrap(httpMock, [{ key: 'logs', label: 'Logs', exists: true }]);
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

    flushSidebarBootstrap(httpMock, [{ key: 'logs', label: 'Logs', exists: true }]);
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

    flushSidebarBootstrap(httpMock, [{ key: 'logs', label: 'Logs', exists: true }]);
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

    flushSidebarBootstrap(httpMock, [{ key: 'logs', label: 'Logs', exists: false }]);
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

    flushSidebarBootstrap(httpMock, [{ key: 'logs', label: 'Logs', exists: false }]);
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

    flushSidebarBootstrap(httpMock, [{ key: 'logs', label: 'Logs', exists: true }]);
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

    nav['activeRootSignal'].set('logs');

    flushSidebarBootstrap(httpMock, [
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

  it('project layout lists workspaces when registry returns entries', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    fixture.detectChanges();
    tick();

    const wsRoot = '/tmp/ws/.ralph-workspace';
    const proj = '/tmp/ws';
    flushSidebarBootstrap(
      httpMock,
      [{ key: 'plans', label: 'Plans', exists: true }],
      {
        projectRoot: proj,
        workspaces: [
          {
            path: proj,
            workspaceRoot: wsRoot,
            projectRoot: proj,
            label: 'ws',
            exists: true,
          },
        ],
      },
    );
    tick();
    flush();
    httpMock.match(() => true).forEach((req) => {
      req.flush({ root: 'plans', path: '', parent: null, entries: [] });
    });
    fixture.detectChanges();

    expect(fixture.componentInstance.useProjectLayout()).toBe(true);
    expect(fixture.componentInstance.sortedWorkspaces().length).toBe(1);
  }));

  it('project layout filters to the selected workspace', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const selector = TestBed.inject(WorkspaceSelectorService);
    fixture.detectChanges();
    tick();

    flushSidebarBootstrap(
      httpMock,
      [{ key: 'plans', label: 'Plans', exists: true }],
      {
        projectRoot: '/tmp/a',
        workspaces: [workspace('/tmp/a'), workspace('/tmp/b')],
      },
    );
    tick();

    selector.selectWorkspace('/tmp/b');
    fixture.detectChanges();

    expect(fixture.componentInstance.sortedWorkspaces().map((w) => w.path)).toEqual(['/tmp/b']);
  }));

  it('uses per-project section availability', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    fixture.detectChanges();
    tick();
    const ws = workspace('/tmp/project', { ...allSections, logs: false, plans: true });

    flushSidebarBootstrap(
      httpMock,
      [
        { key: 'logs', label: 'Logs', exists: true },
        { key: 'plans', label: 'Plans', exists: true },
      ],
      { projectRoot: ws.projectRoot, workspaces: [ws] },
    );
    tick();

    expect(fixture.componentInstance.sectionExists(ws, 'logs')).toBe(false);
    expect(fixture.componentInstance.sectionExists(ws, 'plans')).toBe(true);
  }));

  it('passes projectRoot or workspaceRoot when expanding project sections', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    fixture.detectChanges();
    tick();
    const ws = workspace('/tmp/project');

    flushSidebarBootstrap(
      httpMock,
      [
        { key: 'logs', label: 'Logs', exists: true },
        { key: 'artifacts', label: 'Artifacts', exists: true },
        { key: 'sessions', label: 'Sessions', exists: true },
        { key: 'orchestration-plans', label: 'Orchestration Plans', exists: true },
        { key: 'plans', label: 'Plans', exists: true },
      ],
      { projectRoot: ws.projectRoot, workspaces: [ws] },
    );
    tick();

    for (const section of ['plans', 'sessions', 'orchestration-plans']) {
      fixture.componentInstance.selectSection(ws, section);
      fixture.detectChanges();
      const req = httpMock.expectOne((r) => r.url.includes('/api/list') && r.params.get('root') === section);
      expect(req.request.params.get('projectRoot')).toBe(ws.projectRoot);
      expect(req.request.params.get('workspaceRoot')).toBeNull();
      req.flush({ root: section, path: '', parent: null, entries: [] });
      fixture.componentInstance.toggleSectionExpansion(ws, section);
    }

    for (const section of ['logs', 'artifacts']) {
      fixture.componentInstance.selectSection(ws, section);
      fixture.detectChanges();
      const req = httpMock.expectOne((r) => r.url.includes('/api/list') && r.params.get('root') === section);
      expect(req.request.params.get('workspaceRoot')).toBe(ws.workspaceRoot);
      expect(req.request.params.get('projectRoot')).toBeNull();
      req.flush({ root: section, path: '', parent: null, entries: [] });
      fixture.componentInstance.toggleSectionExpansion(ws, section);
    }
  }));
});
