import {
  AfterViewInit,
  Component,
  ElementRef,
  OnInit,
  QueryList,
  ViewChildren,
  computed,
  effect,
  DestroyRef,
  inject,
  signal,
  untracked,
} from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { IonIcon } from '@ionic/angular/standalone';
import { addIcons } from 'ionicons';
import {
  archiveOutline,
  bookOutline,
  chevronForwardOutline,
  documentTextOutline,
  folderOpenOutline,
  folderOutline,
  layersOutline,
  listOutline,
  terminalOutline,
  timeOutline,
} from 'ionicons/icons';

import { ApiService, Root, WorkspaceRegistry } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { SidebarTreeComponent } from '../sidebar-tree/sidebar-tree.component';

const ROOT_ORDER = ['docs', 'logs', 'orchestration-plans', 'plans', 'artifacts', 'sessions'];

const SECTION_HOST_SEP = '\x1e';

const ROOT_SECTION_KEYS: readonly string[] = ROOT_ORDER;

@Component({
  selector: 'app-workspace-sidebar',
  standalone: true,
  imports: [IonIcon, SidebarTreeComponent],
  templateUrl: './workspace-sidebar.component.html',
  styleUrls: ['./workspace-sidebar.component.scss'],
})
export class WorkspaceSidebarComponent implements OnInit, AfterViewInit {
  private readonly api = inject(ApiService);
  private readonly nav = inject(NavService);
  private readonly workspaceSelector = inject(WorkspaceSelectorService);
  private readonly destroyRef = inject(DestroyRef);
  private readonly hostVisibilityVersion = signal(0);

  roots = signal<Root[]>([]);
  primaryProjectRoot = signal<string | null>(null);

  expandedRoots = signal<Set<string>>(new Set());
  collapsedByUser = signal<Set<string>>(new Set());

  expandedProjects = signal<Set<string>>(new Set());
  collapsedProjectByUser = signal<Set<string>>(new Set());
  expandedSections = signal<Set<string>>(new Set());
  collapsedSectionByUser = signal<Set<string>>(new Set());

  @ViewChildren('legacyRootHost', { read: ElementRef })
  legacyRootHosts!: QueryList<ElementRef<HTMLElement>>;

  @ViewChildren('sectionHost', { read: ElementRef })
  sectionHosts!: QueryList<ElementRef<HTMLElement>>;

  readonly useProjectLayout = computed(() => this.workspaceSelector.workspaces().length >= 1);

  readonly sortedWorkspaces = computed(() => {
    const selected = this.workspaceSelector.selectedWorkspacePath();
    const workspaces = this.workspaceSelector.workspaces().filter((ws) => ws.exists);
    const scoped = selected ? workspaces.filter((ws) => ws.path === selected) : workspaces;
    return [...scoped].sort((a, b) => a.projectRoot.localeCompare(b.projectRoot));
  });

  readonly rootSectionKeys = ROOT_SECTION_KEYS;

  allRoots = computed(() =>
    ROOT_ORDER.map((key) => this.roots().find((r) => r.key === key)).filter((r): r is Root => r !== undefined),
  );

  constructor() {
    addIcons({
      archiveOutline,
      bookOutline,
      chevronForwardOutline,
      documentTextOutline,
      folderOpenOutline,
      folderOutline,
      layersOutline,
      listOutline,
      terminalOutline,
      timeOutline,
    });

    effect(() => {
      this.nav.activeRoot();
      this.nav.activeWorkspaceRoot();
      this.nav.activeProjectRoot();
      this.primaryProjectRoot();
      this.workspaceSelector.workspaces();
      this.useProjectLayout();
      this.hostVisibilityVersion();
      untracked(() => {
        this.autoExpandFromRoute();
        this.ensureActiveSectionVisible();
      });
    });
  }

  ngOnInit(): void {
    this.api.fetchWorkspace().subscribe({
      next: (info) => {
        this.primaryProjectRoot.set(info.root);
      },
      error: () => {
        this.primaryProjectRoot.set(null);
      },
    });

    this.api.fetchRoots().subscribe((roots) => {
      this.roots.set(roots);
    });

    this.workspaceSelector.loadWorkspaces(() => {
      const active = this.nav.activeRoot();
      if (this.useProjectLayout()) {
        this.autoExpandFromRoute();
        return;
      }
      if (active) {
        this.expandedRoots.update((s) => {
          if (this.collapsedByUser().has(active)) return s;
          const next = new Set(s);
          next.add(active);
          return next;
        });
      } else {
        const firstAvailable = this.allRoots().find((r) => r.exists);
        if (firstAvailable) {
          this.selectRoot(firstAvailable);
        }
      }
    });
  }

  ngAfterViewInit(): void {
    this.legacyRootHosts.changes
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(() => this.hostVisibilityVersion.update((v) => v + 1));
    this.sectionHosts.changes
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(() => this.hostVisibilityVersion.update((v) => v + 1));
    this.hostVisibilityVersion.update((v) => v + 1);
  }

  sectionExpansionKey(ws: WorkspaceRegistry, sectionKey: string): string {
    return `${ws.projectRoot}${SECTION_HOST_SEP}${sectionKey}`;
  }

  sectionHostAnchor(ws: WorkspaceRegistry, sectionKey: string): string {
    return this.sectionExpansionKey(ws, sectionKey);
  }

  sectionLabel(sectionKey: string): string {
    return this.roots().find((r) => r.key === sectionKey)?.label ?? sectionKey;
  }

  sectionIcon(sectionKey: string): string {
    switch (sectionKey) {
      case 'docs':
        return 'book-outline';
      case 'logs':
        return 'terminal-outline';
      case 'orchestration-plans':
        return 'layers-outline';
      case 'plans':
        return 'list-outline';
      case 'artifacts':
        return 'archive-outline';
      case 'sessions':
        return 'time-outline';
      default:
        return 'document-text-outline';
    }
  }

  projectIcon(ws: WorkspaceRegistry): string {
    return this.isProjectExpanded(ws) ? 'folder-open-outline' : 'folder-outline';
  }

  visibleSectionKeys(ws: WorkspaceRegistry): readonly string[] {
    return this.rootSectionKeys.filter((sectionKey) => this.sectionExists(ws, sectionKey));
  }

  sectionExists(ws: WorkspaceRegistry, sectionKey: string): boolean {
    return ws.sections?.[sectionKey] ?? this.roots().find((r) => r.key === sectionKey)?.exists ?? false;
  }

  isProjectExpanded(ws: WorkspaceRegistry): boolean {
    if (!ws.exists) return false;
    return this.expandedProjects().has(ws.projectRoot);
  }

  toggleProject(ws: WorkspaceRegistry): void {
    if (!ws.exists) return;
    const was = this.isProjectExpanded(ws);
    this.expandedProjects.update((cur) => {
      const next = new Set(cur);
      if (was) next.delete(ws.projectRoot);
      else next.add(ws.projectRoot);
      return next;
    });
    this.collapsedProjectByUser.update((cur) => {
      const next = new Set(cur);
      if (was) next.add(ws.projectRoot);
      else next.delete(ws.projectRoot);
      return next;
    });
  }

  isSectionExpanded(ws: WorkspaceRegistry, sectionKey: string): boolean {
    if (!ws.exists || !this.sectionExists(ws, sectionKey)) return false;
    return this.expandedSections().has(this.sectionExpansionKey(ws, sectionKey));
  }

  toggleSectionExpansion(ws: WorkspaceRegistry, sectionKey: string): void {
    if (!ws.exists || !this.sectionExists(ws, sectionKey)) return;
    const key = this.sectionExpansionKey(ws, sectionKey);
    const was = this.isSectionExpanded(ws, sectionKey);
    this.expandedSections.update((cur) => {
      const next = new Set(cur);
      if (was) next.delete(key);
      else next.add(key);
      return next;
    });
    this.collapsedSectionByUser.update((cur) => {
      const next = new Set(cur);
      if (was) next.add(key);
      else next.delete(key);
      return next;
    });
  }

  isSectionActive(ws: WorkspaceRegistry, sectionKey: string): boolean {
    if (this.nav.activeRoot() !== sectionKey) return false;
    if (sectionKey === 'logs' || sectionKey === 'artifacts') {
      const aw = this.nav.activeWorkspaceRoot();
      return aw !== null && aw === ws.workspaceRoot;
    }
    const ap = this.nav.activeProjectRoot()?.trim();
    if (ap) {
      return ap === ws.projectRoot;
    }
    const primary = this.primaryProjectRoot();
    return primary !== null && primary === ws.projectRoot;
  }

  listingWorkspaceScopeForTree(ws: WorkspaceRegistry, sectionKey: string): string | null {
    if (sectionKey === 'logs' || sectionKey === 'artifacts') {
      return ws.workspaceRoot;
    }
    return null;
  }

  projectRootForTree(ws: WorkspaceRegistry, sectionKey: string): string | null {
    if (sectionKey === 'logs' || sectionKey === 'artifacts') {
      return null;
    }
    return ws.projectRoot;
  }

  selectSection(ws: WorkspaceRegistry, sectionKey: string): void {
    if (!ws.exists || !this.sectionExists(ws, sectionKey)) return;
    this.collapsedProjectByUser.update((cur) => {
      const next = new Set(cur);
      next.delete(ws.projectRoot);
      return next;
    });
    this.collapsedSectionByUser.update((cur) => {
      const next = new Set(cur);
      next.delete(this.sectionExpansionKey(ws, sectionKey));
      return next;
    });
    this.expandedProjects.update((cur) => {
      const next = new Set(cur);
      next.add(ws.projectRoot);
      return next;
    });
    this.expandedSections.update((cur) => {
      const next = new Set(cur);
      next.add(this.sectionExpansionKey(ws, sectionKey));
      return next;
    });
    if (sectionKey === 'logs' || sectionKey === 'artifacts') {
      this.nav.navigate(sectionKey, null, null, ws.workspaceRoot, null);
    } else {
      this.nav.navigate(sectionKey, null, null, null, ws.projectRoot);
    }
  }

  private autoExpandFromRoute(): void {
    if (!this.useProjectLayout()) return;
    const root = this.nav.activeRoot();
    if (!root) return;
    let ws: WorkspaceRegistry | undefined;
    if (root === 'logs' || root === 'artifacts') {
      const w = this.nav.activeWorkspaceRoot();
      if (!w) return;
      ws = this.sortedWorkspaces().find((x) => x.workspaceRoot === w);
    } else {
      let p = this.nav.activeProjectRoot()?.trim();
      if (!p) {
        p = this.primaryProjectRoot() ?? undefined;
      }
      if (!p) return;
      ws = this.sortedWorkspaces().find((x) => x.projectRoot === p);
    }
    if (!ws) return;
    if (this.collapsedProjectByUser().has(ws.projectRoot)) return;
    if (this.collapsedSectionByUser().has(this.sectionExpansionKey(ws, root))) return;
    this.expandedProjects.update((cur) => {
      const next = new Set(cur);
      next.add(ws!.projectRoot);
      return next;
    });
    this.expandedSections.update((cur) => {
      const next = new Set(cur);
      next.add(this.sectionExpansionKey(ws!, root));
      return next;
    });
  }

  private ensureActiveSectionVisible(): void {
    const activeRootKey = this.nav.activeRoot();
    if (!activeRootKey) return;
    Promise.resolve().then(() => {
      if (this.useProjectLayout()) {
        if (!this.sectionHosts?.length) return;
        const anchor = this.activeSectionAnchor();
        if (!anchor) return;
        const el = this.sectionHosts.find((ref) => ref.nativeElement.dataset['sectionAnchor'] === anchor);
        el?.nativeElement.scrollIntoView({ block: 'nearest' });
        return;
      }
      if (!this.legacyRootHosts?.length) return;
      const el = this.legacyRootHosts.find((ref) => ref.nativeElement.dataset['rootKey'] === activeRootKey);
      el?.nativeElement.scrollIntoView({ block: 'nearest' });
    });
  }

  private activeSectionAnchor(): string | null {
    const r = this.nav.activeRoot();
    if (!r) return null;
    if (r === 'logs' || r === 'artifacts') {
      const w = this.nav.activeWorkspaceRoot();
      if (!w) return null;
      const ws = this.sortedWorkspaces().find((x) => x.workspaceRoot === w);
      return ws ? this.sectionHostAnchor(ws, r) : null;
    }
    let p = this.nav.activeProjectRoot()?.trim();
    if (!p) p = this.primaryProjectRoot() ?? undefined;
    if (!p) return null;
    const ws = this.sortedWorkspaces().find((x) => x.projectRoot === p);
    return ws ? this.sectionHostAnchor(ws, r) : null;
  }

  isExpanded(root: Root): boolean {
    return this.expandedRoots().has(root.key);
  }

  isActive(root: Root): boolean {
    return this.nav.activeRoot() === root.key;
  }

  rootMeta(root: Root): string {
    if (!root.exists) {
      return 'Section unavailable';
    }
    return 'Browse entries';
  }

  toggleExpansion(root: Root): void {
    if (!root.exists) return;
    const isCurrentlyExpanded = this.expandedRoots().has(root.key);
    this.expandedRoots.update((current) => {
      const next = new Set(current);
      if (isCurrentlyExpanded) {
        next.delete(root.key);
      } else {
        next.add(root.key);
      }
      return next;
    });
    this.collapsedByUser.update((current) => {
      const next = new Set(current);
      if (isCurrentlyExpanded) {
        next.add(root.key);
      } else {
        next.delete(root.key);
      }
      return next;
    });
  }

  listingScope(root: Root): string | null {
    if (this.nav.activeRoot() !== root.key) {
      return null;
    }
    return this.nav.activeWorkspaceRoot();
  }

  selectRoot(root: Root): void {
    if (!root.exists) return;
    this.collapsedByUser.update((current) => {
      const next = new Set(current);
      next.delete(root.key);
      return next;
    });
    this.expandedRoots.update((current) => {
      const next = new Set(current);
      next.add(root.key);
      return next;
    });
    this.nav.navigate(root.key);
  }
}
