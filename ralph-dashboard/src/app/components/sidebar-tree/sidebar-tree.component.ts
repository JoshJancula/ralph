import { CommonModule } from '@angular/common';
import { Component, Input, inject, signal, OnInit } from '@angular/core';
import { ApiService, ListingEntry } from '../../services/api.service';
import { NavService } from '../../services/nav.service';

interface TreeNode {
  name: string;
  path: string;
  type: 'file' | 'dir';
  size?: number;
  mtime: number;
  depth: number;
  expanded: boolean;
  loading: boolean;
  requestToken: number;
  children: TreeNode[] | null; // null = not loaded, [] = loaded empty
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

@Component({
  selector: 'app-sidebar-tree',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './sidebar-tree.component.html',
  styleUrls: ['./sidebar-tree.component.scss'],
})
export class SidebarTreeComponent implements OnInit {
  private readonly api = inject(ApiService);
  private readonly nav = inject(NavService);
  private nextRequestToken = 0;

  @Input() set root(value: string) {
    this._root = value;
  }
  get root(): string { return this._root; }
  private _root = '';

  @Input() set path(value: string) {
    this._path = value;
  }
  get path(): string { return this._path; }
  private _path = '';

  @Input() autoOpen = false;

  rootNodes = signal<TreeNode[]>([]);
  flatNodes = signal<TreeNode[]>([]);
  loading = signal(false);
  error = signal<string | null>(null);

  treeData(): TreeNode[] {
    return this.flatNodes();
  }

  ngOnInit(): void {
    if (!this._root) return;
    this.loadRoot();
  }

  loadRoot(): void {
    this.loading.set(true);
    this.error.set(null);
    this.api.fetchListing(this._root, this._path).subscribe({
      next: (listing) => {
        const nodes = listing.entries.map(e => this.entryToNode(e, 0));
        this.rootNodes.set(nodes);
        this.rebuildFlat();
        this.loading.set(false);
        if (this.autoOpen && !this.nav.activeFile()) {
          this.openFirstFile(nodes);
        }
      },
      error: () => {
        this.error.set('Failed to load directory listing');
        this.loading.set(false);
      },
    });
  }

  private entryToNode(entry: ListingEntry, depth: number): TreeNode {
    return {
      name: entry.name,
      path: entry.path,
      type: entry.type,
      size: entry.size,
      mtime: entry.mtime,
      depth,
      expanded: false,
      loading: false,
      requestToken: 0,
      children: null,
    };
  }

  private rebuildFlat(): void {
    const flat: TreeNode[] = [];
    this.walkVisible(this.rootNodes(), flat);
    this.flatNodes.set(flat);
  }

  private walkVisible(nodes: TreeNode[], out: TreeNode[]): void {
    for (const node of nodes) {
      out.push(node);
      if (node.type === 'dir' && node.expanded && node.children) {
        this.walkVisible(node.children, out);
      }
    }
  }

  toggleDirectory(node: TreeNode): void {
    if (node.type !== 'dir') return;

    if (node.loading) {
      node.requestToken = ++this.nextRequestToken;
      node.loading = false;
      node.expanded = false;
      this.rebuildFlat();
      return;
    }

    if (node.expanded) {
      node.expanded = false;
      this.rebuildFlat();
      return;
    }

    if (node.children !== null) {
      node.expanded = true;
      this.rebuildFlat();
      return;
    }

    const requestToken = ++this.nextRequestToken;
    node.requestToken = requestToken;
    node.loading = true;
    this.rebuildFlat();

    this.api.fetchListing(this._root, node.path).subscribe({
      next: (listing) => {
        if (node.requestToken !== requestToken) return;
        node.children = listing.entries.map(e => this.entryToNode(e, node.depth + 1));
        node.expanded = true;
        node.loading = false;
        this.rebuildFlat();
        if (this.autoOpen && !this.nav.activeFile()) {
          this.openFirstFile(node.children);
        }
      },
      error: () => {
        if (node.requestToken !== requestToken) return;
        node.loading = false;
        node.expanded = false;
        this.rebuildFlat();
      },
    });
  }

  selectEntry(node: TreeNode): void {
    if (node.type === 'dir') {
      this.toggleDirectory(node);
    } else {
      this.nav.navigate(this._root, '', node.path);
    }
  }

  isSelected(node: TreeNode): boolean {
    return this.nav.activeFile() === node.path;
  }

  private openFirstFile(nodes: TreeNode[]): void {
    for (const node of nodes) {
      if (node.type === 'file') {
        this.nav.navigate(this._root, '', node.path);
        return;
      }
    }
    // If all are directories, expand the first and try again
    if (nodes.length > 0 && nodes[0].type === 'dir') {
      this.toggleDirectory(nodes[0]);
    }
  }

  formatSize(node: TreeNode): string {
    if (node.type === 'dir') return '';
    if (node.size === undefined) return '';
    return formatSize(node.size);
  }

  indentPx(node: TreeNode): number {
    const baseIndent = node.depth * 12 + 6;
    const marginOffset = 4; // account for the left margin so nodes stay aligned
    return Math.max(0, baseIndent - marginOffset);
  }
}
