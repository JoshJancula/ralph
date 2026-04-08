import { CommonModule } from '@angular/common';
import {
  AfterViewInit,
  Component,
  ElementRef,
  OnDestroy,
  OnInit,
  QueryList,
  ViewChildren,
  computed,
  effect,
  inject,
  signal,
} from '@angular/core';


import { ApiService, Root } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { SidebarTreeComponent } from '../sidebar-tree/sidebar-tree.component';

const ROOT_ORDER = ['docs', 'logs', 'orchestration-plans', 'plans', 'artifacts', 'sessions'];

@Component({
  selector: 'app-workspace-sidebar',
  standalone: true,
  imports: [CommonModule, SidebarTreeComponent],
  templateUrl: './workspace-sidebar.component.html',
  styleUrls: ['./workspace-sidebar.component.scss'],
})
export class WorkspaceSidebarComponent implements OnInit, AfterViewInit, OnDestroy {
  private readonly api = inject(ApiService);
  private readonly nav = inject(NavService);

  roots = signal<Root[]>([]);
  expandedRoots = signal<Set<string>>(new Set());
  collapsedByUser = signal<Set<string>>(new Set());

  @ViewChildren('rootHost', { read: ElementRef })
  rootHosts!: QueryList<ElementRef<HTMLElement>>;

  allRoots = computed(() => {
    const available = this.roots();
    return ROOT_ORDER
      .map(key => available.find(r => r.key === key))
      .filter((r): r is Root => r !== undefined);
  });

  constructor() {
    effect(() => {
      const activeRoot = this.nav.activeRoot();
      if (activeRoot) {
        this.ensureActiveRootVisible();
      }
    });
  }

  ngOnInit(): void {
    this.api.fetchRoots().subscribe((roots) => {
      this.roots.set(roots);
      const active = this.nav.activeRoot();
      if (active) {
        this.expandedRoots.update((s) => {
          if (this.collapsedByUser().has(active)) return s;
          const next = new Set(s);
          next.add(active);
          return next;
        });
      } else {
        // Auto-select the first available root on initial load
        const firstAvailable = this.allRoots().find(r => r.exists);
        if (firstAvailable) {
          this.selectRoot(firstAvailable);
        }
      }
    });
  }

  ngAfterViewInit(): void {
    this.rootHosts.changes.subscribe(() => this.ensureActiveRootVisible());
    this.ensureActiveRootVisible();
  }

  ngOnDestroy(): void {
  }

  isExpanded(root: Root): boolean {
    return this.expandedRoots().has(root.key);
  }

  isActive(root: Root): boolean {
    return this.nav.activeRoot() === root.key;
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

  selectRoot(root: Root): void {
    if (!root.exists) return;
    this.nav.navigate(root.key);
    if (!this.collapsedByUser().has(root.key)) {
      this.expandedRoots.update((current) => {
        const next = new Set(current);
        next.add(root.key);
        return next;
      });
    }
    this.ensureActiveRootVisible();
  }

  private ensureActiveRootVisible(): void {
    const activeRootKey = this.nav.activeRoot();
    if (!activeRootKey || !this.rootHosts) {
      return;
    }
    Promise.resolve().then(() => {
      const el = this.rootHosts.find(
        (ref) => ref.nativeElement.dataset['rootKey'] === activeRootKey,
      );
      el?.nativeElement.scrollIntoView({ block: 'nearest' });
    });
  }
}
