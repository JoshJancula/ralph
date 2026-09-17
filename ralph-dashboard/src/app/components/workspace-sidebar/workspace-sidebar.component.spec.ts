import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ElementRef, QueryList } from '@angular/core';
import { TestBed, fakeAsync, tick, flush } from '@angular/core/testing';
import { Subject } from 'rxjs';
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

  it('shows a loading skeleton (never the legacy root list) before workspaces() has responded, even when the eventual list is empty', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    Object.assign(fixture.componentInstance, { workspaceExplorerEnabled: true });
    // Preserve coverage for the parked explorer's loading state.
    fixture.componentInstance['nav']['activeSectionSignal'].set('browse');
    fixture.detectChanges();
    tick();

    let el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="sidebar-loading-skeleton"]')).not.toBeNull();
    expect(el.querySelector('.root-item')).toBeNull();
    expect(el.querySelector('.project-block')).toBeNull();

    flushSidebarBootstrap(httpMock, [{ key: 'logs', label: 'Logs', exists: true }], { workspaces: [] });
    tick();
    flush();
    httpMock.match(() => true).forEach((req) => req.flush({}));
    tick();
    fixture.detectChanges();

    el = fixture.nativeElement;
    expect(el.querySelector('[data-testid="sidebar-loading-skeleton"]')).toBeNull();
    expect(el.querySelector('.root-item')).not.toBeNull();
    flush();
  }));

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
    Object.assign(fixture.componentInstance, { workspaceExplorerEnabled: true });
    const nav = TestBed.inject(NavService);
    const navigateSpy = vi.spyOn(nav, 'navigate').mockImplementation(() => {});
    const scrollSpy = vi.mocked(Element.prototype.scrollIntoView);

    nav['activeRootSignal'].set(null);
    // The browse tree only renders in the Browse section (separate-primary-navigation).
    nav['activeSectionSignal'].set('browse');

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
    const nav = TestBed.inject(NavService);
    const navigateSpy = vi.spyOn(nav, 'navigate').mockImplementation(() => {});
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

    // selectSection only navigates now; the destination route/component owns the actual
    // listing fetch (moved out of the sidebar by the separate-primary-navigation redesign).
    for (const section of ['plans', 'sessions', 'orchestration-plans']) {
      navigateSpy.mockClear();
      fixture.componentInstance.selectSection(ws, section);
      expect(navigateSpy).toHaveBeenCalledWith(section, null, null, null, ws.projectRoot);
      fixture.componentInstance.toggleSectionExpansion(ws, section);
    }

    for (const section of ['logs', 'artifacts']) {
      navigateSpy.mockClear();
      fixture.componentInstance.selectSection(ws, section);
      expect(navigateSpy).toHaveBeenCalledWith(section, null, null, ws.workspaceRoot, null);
      fixture.componentInstance.toggleSectionExpansion(ws, section);
    }
  }));

  describe('project layout helpers and conditional paths', () => {
    function bootProjectSidebar(
      workspaces: WorkspaceRegistry[],
      roots: Root[] = [
        { key: 'docs', label: 'Docs', exists: true },
        { key: 'logs', label: 'Logs', exists: true },
        { key: 'orchestration-plans', label: 'Orchestration', exists: true },
        { key: 'graph-runs', label: 'Graph', exists: true },
        { key: 'plans', label: 'Plans', exists: true },
        { key: 'artifacts', label: 'Artifacts', exists: true },
        { key: 'sessions', label: 'Sessions', exists: true },
      ],
    ) {
      const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
      fixture.detectChanges();
      tick();
      flushSidebarBootstrap(httpMock, roots, {
        projectRoot: workspaces[0]?.projectRoot ?? '/tmp/project',
        workspaces,
      });
      tick();
      flush();
      httpMock.match(() => true).forEach((req) => {
        req.flush({ root: 'plans', path: '', parent: null, entries: [] });
      });
      fixture.detectChanges();
      return fixture;
    }

    it('maps section icons and labels including unknown keys', fakeAsync(() => {
      const ws = workspace('/tmp/project');
      const fixture = bootProjectSidebar([ws]);
      const comp = fixture.componentInstance;

      expect(comp.sectionIcon('docs')).toBe('book-outline');
      expect(comp.sectionIcon('logs')).toBe('terminal-outline');
      expect(comp.sectionIcon('orchestration-plans')).toBe('layers-outline');
      expect(comp.sectionIcon('graph-runs')).toBe('layers-outline');
      expect(comp.sectionIcon('plans')).toBe('list-outline');
      expect(comp.sectionIcon('artifacts')).toBe('archive-outline');
      expect(comp.sectionIcon('sessions')).toBe('time-outline');
      expect(comp.sectionIcon('unknown')).toBe('document-text-outline');
      expect(comp.sectionLabel('plans')).toBe('Plans');
      expect(comp.sectionLabel('missing-key')).toBe('missing-key');
    }));

    it('sorts Ralph docs workspace first and ignores missing workspaces', fakeAsync(() => {
      const docsWs: WorkspaceRegistry = {
        ...workspace('/tmp/ralph-docs'),
        label: 'Ralph docs',
      };
      const other = workspace('/tmp/zeta');
      const missing = { ...workspace('/tmp/gone'), exists: false };
      const fixture = bootProjectSidebar([other, docsWs, missing]);
      expect(fixture.componentInstance.sortedWorkspaces().map((w) => w.label)).toEqual(['Ralph docs', 'zeta']);
    }));

    it('toggles project and section expansion with collapsed-by-user tracking', fakeAsync(() => {
      const ws = workspace('/tmp/project');
      const fixture = bootProjectSidebar([ws]);
      const comp = fixture.componentInstance;

      comp.expandedProjects.set(new Set());
      expect(comp.projectIcon(ws)).toBe('folder-outline');
      comp.toggleProject(ws);
      expect(comp.isProjectExpanded(ws)).toBe(true);
      expect(comp.projectIcon(ws)).toBe('folder-open-outline');
      comp.toggleProject(ws);
      expect(comp.isProjectExpanded(ws)).toBe(false);

      const missingWs = { ...ws, exists: false };
      comp.toggleProject(missingWs);
      expect(comp.isProjectExpanded(missingWs)).toBe(false);

      comp.expandedSections.set(new Set());
      expect(comp.isSectionExpanded(ws, 'plans')).toBe(false);
      comp.toggleSectionExpansion(ws, 'plans');
      expect(comp.isSectionExpanded(ws, 'plans')).toBe(true);
      comp.toggleSectionExpansion(ws, 'plans');
      expect(comp.isSectionExpanded(ws, 'plans')).toBe(false);
      comp.toggleSectionExpansion(ws, 'logs');
      expect(comp.isSectionExpanded({ ...ws, exists: false }, 'plans')).toBe(false);
      comp.toggleSectionExpansion({ ...ws, sections: { ...allSections, plans: false } }, 'plans');
    }));

    it('computes section activity for logs/artifacts and project-scoped roots', fakeAsync(() => {
      const ws = workspace('/tmp/project');
      const other = workspace('/tmp/other');
      const fixture = bootProjectSidebar([ws, other]);
      const comp = fixture.componentInstance;
      const nav = TestBed.inject(NavService);

      nav['activeRootSignal'].set('plans');
      nav['activeProjectRootSignal'].set('/tmp/project');
      expect(comp.isSectionActive(ws, 'plans')).toBe(true);
      expect(comp.isSectionActive(other, 'plans')).toBe(false);

      nav['activeRootSignal'].set('logs');
      nav['activeWorkspaceRootSignal'].set(ws.workspaceRoot);
      expect(comp.isSectionActive(ws, 'logs')).toBe(true);
      expect(comp.isSectionActive(other, 'logs')).toBe(false);
      expect(comp.isSectionActive(ws, 'plans')).toBe(false);

      nav['activeRootSignal'].set('sessions');
      nav['activeProjectRootSignal'].set(null);
      comp.primaryProjectRoot.set(ws.projectRoot);
      expect(comp.isSectionActive(ws, 'sessions')).toBe(true);
      expect(comp.isSectionActive(other, 'sessions')).toBe(false);

      expect(comp.listingWorkspaceScopeForTree(ws, 'logs')).toBe(ws.workspaceRoot);
      expect(comp.listingWorkspaceScopeForTree(ws, 'plans')).toBeNull();
      expect(comp.projectRootForTree(ws, 'artifacts')).toBeNull();
      expect(comp.projectRootForTree(ws, 'plans')).toBe(ws.projectRoot);
    }));

    it('auto-expands from route for workspace and project roots', fakeAsync(() => {
      const ws = workspace('/tmp/project');
      const fixture = bootProjectSidebar([ws]);
      const comp = fixture.componentInstance;
      const nav = TestBed.inject(NavService);

      nav['activeRootSignal'].set('logs');
      nav['activeWorkspaceRootSignal'].set(ws.workspaceRoot);
      fixture.detectChanges();
      flush();
      expect(comp.isProjectExpanded(ws)).toBe(true);
      expect(comp.isSectionExpanded(ws, 'logs')).toBe(true);

      comp.expandedProjects.set(new Set());
      comp.expandedSections.set(new Set());
      comp.collapsedProjectByUser.set(new Set([ws.projectRoot]));
      nav['activeRootSignal'].set('plans');
      nav['activeProjectRootSignal'].set(ws.projectRoot);
      fixture.detectChanges();
      flush();
      expect(comp.isProjectExpanded(ws)).toBe(false);
      expect(comp.isSectionExpanded(ws, 'plans')).toBe(false);

      comp.collapsedProjectByUser.set(new Set());
      comp.collapsedSectionByUser.set(new Set([comp.sectionExpansionKey(ws, 'plans')]));
      fixture.detectChanges();
      flush();
      expect(comp.isSectionExpanded(ws, 'plans')).toBe(false);

      comp.collapsedSectionByUser.set(new Set());
      nav['activeRootSignal'].set('sessions');
      nav['activeProjectRootSignal'].set(null);
      comp.primaryProjectRoot.set(ws.projectRoot);
      fixture.detectChanges();
      flush();
      expect(comp.isSectionExpanded(ws, 'sessions')).toBe(true);
    }));

    it('selectSection ignores missing sections and rootMeta reports unavailable roots', fakeAsync(() => {
      const ws = workspace('/tmp/project', { ...allSections, plans: false });
      const fixture = bootProjectSidebar([ws]);
      const nav = TestBed.inject(NavService);
      const spy = vi.spyOn(nav, 'navigate').mockImplementation(() => {});
      fixture.componentInstance.selectSection(ws, 'plans');
      expect(spy).not.toHaveBeenCalled();

      expect(fixture.componentInstance.rootMeta({ key: 'plans', label: 'Plans', exists: false })).toBe(
        'Section unavailable',
      );
      expect(fixture.componentInstance.rootMeta({ key: 'plans', label: 'Plans', exists: true })).toBe('Browse entries');
      expect(fixture.componentInstance.listingScope({ key: 'plans', label: 'Plans', exists: true })).toBeNull();
    }));

    it('handles workspace fetch errors and selects first available legacy root', fakeAsync(() => {
      const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
      const nav = TestBed.inject(NavService);
      const navigateSpy = vi.spyOn(nav, 'navigate').mockImplementation(() => {});
      nav['activeRootSignal'].set(null);

      fixture.detectChanges();
      tick();

      httpMock.expectOne((r) => r.url.includes('/api/workspace') && !r.url.includes('/api/workspaces')).flush(
        { message: 'boom' },
        { status: 500, statusText: 'Error' },
      );
      httpMock.expectOne((r) => r.url.includes('/api/roots')).flush([
        { key: 'logs', label: 'Logs', exists: false },
        { key: 'plans', label: 'Plans', exists: true },
      ]);
      httpMock.expectOne((r) => r.url.includes('/api/workspaces')).flush([]);
      tick();
      flush();

      expect(fixture.componentInstance.primaryProjectRoot()).toBeNull();
      expect(navigateSpy).toHaveBeenCalledWith('plans');
    }));

    it('toggleBrowseSection switches between browse and plans', fakeAsync(() => {
      const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
      const nav = TestBed.inject(NavService);
      const spy = vi.spyOn(nav, 'navigate').mockImplementation(() => {});
      fixture.detectChanges();
      tick();
      flushSidebarBootstrap(httpMock, [{ key: 'plans', label: 'Plans', exists: true }]);
      tick();
      flush();

      nav['activeSectionSignal'].set('browse');
      fixture.componentInstance.toggleBrowseSection();
      expect(spy).toHaveBeenCalledWith('plans');

      nav['activeSectionSignal'].set('plans');
      fixture.componentInstance.toggleBrowseSection();
      expect(spy).toHaveBeenCalledWith('docs');
    }));

    it('sorts docs workspace when it is the second comparator argument', fakeAsync(() => {
      const alpha = workspace('/tmp/alpha');
      const docsWs: WorkspaceRegistry = { ...workspace('/tmp/ralph-docs'), label: 'Ralph docs' };
      const beta = workspace('/tmp/beta');
      const fixture = bootProjectSidebar([alpha, beta, docsWs]);
      expect(fixture.componentInstance.sortedWorkspaces().map((w) => w.label)[0]).toBe('Ralph docs');
      expect(fixture.componentInstance.sectionHostAnchor(alpha, 'plans')).toBe(
        fixture.componentInstance.sectionExpansionKey(alpha, 'plans'),
      );
    }));

    it('falls back to roots.exists when workspace sections omit a key', fakeAsync(() => {
      const ws = workspace('/tmp/project', { plans: true } as Record<string, boolean>);
      delete (ws.sections as Record<string, boolean> | undefined)?.['logs'];
      ws.sections = { plans: true };
      const fixture = bootProjectSidebar([ws], [
        { key: 'plans', label: 'Plans', exists: true },
        { key: 'logs', label: 'Logs', exists: true },
        { key: 'artifacts', label: 'Artifacts', exists: false },
      ]);
      const comp = fixture.componentInstance;
      expect(comp.sectionExists(ws, 'plans')).toBe(true);
      expect(comp.sectionExists(ws, 'logs')).toBe(true);
      expect(comp.sectionExists(ws, 'artifacts')).toBe(false);
      expect(comp.visibleSectionKeys(ws)).toEqual(['logs', 'plans']);
    }));

    it('skips auto-expand when route scope is missing or workspace is unknown', fakeAsync(() => {
      const ws = workspace('/tmp/project');
      const fixture = bootProjectSidebar([ws]);
      const comp = fixture.componentInstance;
      const nav = TestBed.inject(NavService);

      comp.expandedProjects.set(new Set());
      comp.expandedSections.set(new Set());
      nav['activeRootSignal'].set(null);
      fixture.detectChanges();
      flush();
      expect(comp.expandedProjects().size).toBe(0);

      nav['activeRootSignal'].set('logs');
      nav['activeWorkspaceRootSignal'].set(null);
      fixture.detectChanges();
      flush();
      expect(comp.isProjectExpanded(ws)).toBe(false);

      nav['activeWorkspaceRootSignal'].set('/tmp/unknown/.ralph-workspace');
      fixture.detectChanges();
      flush();
      expect(comp.isProjectExpanded(ws)).toBe(false);

      nav['activeRootSignal'].set('plans');
      nav['activeProjectRootSignal'].set(null);
      comp.primaryProjectRoot.set(null);
      fixture.detectChanges();
      flush();
      expect(comp.isProjectExpanded(ws)).toBe(false);

      nav['activeProjectRootSignal'].set('/tmp/missing');
      fixture.detectChanges();
      flush();
      expect(comp.isProjectExpanded(ws)).toBe(false);
    }));

    it('does not re-expand a legacy root the user collapsed', fakeAsync(() => {
      const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
      const nav = TestBed.inject(NavService);
      nav['activeRootSignal'].set('plans');
      fixture.detectChanges();
      tick();
      fixture.componentInstance.collapsedByUser.set(new Set(['plans']));
      fixture.componentInstance.expandedRoots.set(new Set());
      flushSidebarBootstrap(httpMock, [{ key: 'plans', label: 'Plans', exists: true }]);
      tick();
      flush();
      expect(fixture.componentInstance.expandedRoots().has('plans')).toBe(false);
    }));

    it('scrolls the active project section when hosts are present', fakeAsync(() => {
      const ws = workspace('/tmp/project');
      const fixture = bootProjectSidebar([ws]);
      const comp = fixture.componentInstance;
      const nav = TestBed.inject(NavService);
      const scrollIntoView = vi.fn();
      const anchor = comp.sectionHostAnchor(ws, 'plans');

      nav['activeRootSignal'].set('plans');
      nav['activeProjectRootSignal'].set(ws.projectRoot);
      Object.defineProperty(comp, 'sectionHosts', {
        configurable: true,
        get: () => [
          {
            nativeElement: {
              dataset: { sectionAnchor: anchor },
              scrollIntoView,
            },
          },
        ],
      });
      fixture.detectChanges();
      flush();
      tick();
      expect(scrollIntoView).toHaveBeenCalled();
    }));

    it('bumps host visibility when sectionHosts changes and honors collapsed section + anchors', fakeAsync(() => {
      const ws = workspace('/tmp/project');
      const fixture = bootProjectSidebar([ws]);
      const comp = fixture.componentInstance;
      const nav = TestBed.inject(NavService);

      const sectionChanges$ = new Subject<QueryList<ElementRef<HTMLElement>>>();
      const legacyChanges$ = new Subject<QueryList<ElementRef<HTMLElement>>>();
      const sectionQl = new QueryList<ElementRef<HTMLElement>>();
      const legacyQl = new QueryList<ElementRef<HTMLElement>>();
      Object.defineProperty(sectionQl, 'changes', { configurable: true, value: sectionChanges$ });
      Object.defineProperty(legacyQl, 'changes', { configurable: true, value: legacyChanges$ });
      Object.defineProperty(comp, 'sectionHosts', { configurable: true, value: sectionQl });
      Object.defineProperty(comp, 'legacyRootHosts', { configurable: true, value: legacyQl });
      comp.ngAfterViewInit();
      const before = comp['hostVisibilityVersion']();
      sectionChanges$.next(sectionQl);
      expect(comp['hostVisibilityVersion']()).toBe(before + 1);

      comp.expandedProjects.set(new Set());
      comp.expandedSections.set(new Set());
      comp.collapsedSectionByUser.set(new Set([comp.sectionExpansionKey(ws, 'plans')]));
      nav['activeRootSignal'].set('plans');
      nav['activeProjectRootSignal'].set(ws.projectRoot);
      fixture.detectChanges();
      flush();
      expect(comp.isSectionExpanded(ws, 'plans')).toBe(false);

      nav['activeRootSignal'].set('logs');
      nav['activeWorkspaceRootSignal'].set(null);
      expect(
        (
          comp as unknown as { activeSectionAnchor: () => string | null }
        ).activeSectionAnchor(),
      ).toBeNull();

      nav['activeWorkspaceRootSignal'].set(ws.workspaceRoot);
      expect(
        (
          comp as unknown as { activeSectionAnchor: () => string | null }
        ).activeSectionAnchor(),
      ).toBe(comp.sectionHostAnchor(ws, 'logs'));

      nav['activeRootSignal'].set('artifacts');
      nav['activeWorkspaceRootSignal'].set('/tmp/missing/.ralph-workspace');
      expect(
        (
          comp as unknown as { activeSectionAnchor: () => string | null }
        ).activeSectionAnchor(),
      ).toBeNull();

      nav['activeRootSignal'].set('sessions');
      nav['activeProjectRootSignal'].set(null);
      comp.primaryProjectRoot.set(null);
      expect(
        (
          comp as unknown as { activeSectionAnchor: () => string | null }
        ).activeSectionAnchor(),
      ).toBeNull();

      comp.primaryProjectRoot.set(ws.projectRoot);
      expect(
        (
          comp as unknown as { activeSectionAnchor: () => string | null }
        ).activeSectionAnchor(),
      ).toBe(comp.sectionHostAnchor(ws, 'sessions'));
    }));
  });
});
