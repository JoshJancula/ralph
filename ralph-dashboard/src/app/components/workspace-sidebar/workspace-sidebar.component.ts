import { CommonModule } from '@angular/common';
import { Component, inject, signal, computed, OnInit } from '@angular/core';
import { ApiService, Root } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { SidebarTreeComponent } from '../sidebar-tree/sidebar-tree.component';

const ROOT_ORDER = ['artifacts', 'logs', 'orchestration-plans', 'plans', 'sessions', 'docs'];

@Component({
  selector: 'app-workspace-sidebar',
  standalone: true,
  imports: [CommonModule, SidebarTreeComponent],
  templateUrl: './workspace-sidebar.component.html',
  styleUrls: ['./workspace-sidebar.component.scss'],
})
export class WorkspaceSidebarComponent implements OnInit {
  private readonly api = inject(ApiService);
  private readonly nav = inject(NavService);

  roots = signal<Root[]>([]);
  expandedRoots = signal<Set<string>>(new Set());

  allRoots = computed(() => {
    const available = this.roots();
    return ROOT_ORDER
      .map(key => available.find(r => r.key === key))
      .filter((r): r is Root => r !== undefined);
  });

  ngOnInit(): void {
    this.api.fetchRoots().subscribe((roots) => {
      this.roots.set(roots);
      // Auto-expand the active root if one is set
      const active = this.nav.activeRoot();
      if (active) {
        this.expandedRoots.update(s => { const n = new Set(s); n.add(active); return n; });
      }
    });
  }

  isExpanded(root: Root): boolean {
    return this.expandedRoots().has(root.key);
  }

  isActive(root: Root): boolean {
    return this.nav.activeRoot() === root.key;
  }

  toggleRoot(root: Root): void {
    if (!root.exists) return;
    this.nav.navigate(root.key);
    this.expandedRoots.update(s => {
      const n = new Set(s);
      if (n.has(root.key)) {
        n.delete(root.key);
      } else {
        n.add(root.key);
      }
      return n;
    });
  }

  selectRoot(root: Root): void {
    this.toggleRoot(root);
  }
}
