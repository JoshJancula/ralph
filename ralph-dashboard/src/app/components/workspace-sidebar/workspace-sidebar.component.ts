import { CommonModule } from '@angular/common';
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
} from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';


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
export class WorkspaceSidebarComponent implements OnInit, AfterViewInit {
  private readonly api = inject(ApiService);
  private readonly nav = inject(NavService);
  private readonly destroyRef = inject(DestroyRef);
  private readonly rootHostsVisibilityVersion = signal(0);

  roots = signal<Root[]>([]);
  expandedRoots = signal<Set<string>>(new Set());
  collapsedByUser = signal<Set<string>>(new Set());

  @ViewChildren('rootHost', { read: ElementRef })
  rootHosts!: QueryList<ElementRef<HTMLElement>>;

  allRoots = computed(() =>
    ROOT_ORDER
      .map(key => this.roots().find(r => r.key === key))
      .filter((r): r is Root => r !== undefined)
  );

  constructor() {
    effect(() => {
      this.nav.activeRoot();
      this.rootHostsVisibilityVersion();
      this.ensureActiveRootVisible();
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
    this.rootHosts.changes
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(() => {
        this.rootHostsVisibilityVersion.update((version) => version + 1);
      });
    this.rootHostsVisibilityVersion.update((version) => version + 1);
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

  private ensureActiveRootVisible(): void {
    const activeRootKey = this.nav.activeRoot();
    if (!activeRootKey || !this.rootHosts?.length) {
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
