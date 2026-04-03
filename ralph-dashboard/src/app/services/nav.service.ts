import { Injectable, inject, signal, effect } from '@angular/core';
import { NavigationEnd, Router } from '@angular/router';
import { filter } from 'rxjs';

@Injectable({
  providedIn: 'root',
})
export class NavService {
  private readonly router = inject(Router);
  private readonly activeRootSignal = signal<string | null>(null);
  private readonly activePathSignal = signal<string | null>(null);
  private readonly activeFileSignal = signal<string | null>(null);
  private readonly modeSignal = signal<'hub' | 'file'>('hub');
  private initialized = false;

  readonly activeRoot = this.activeRootSignal.asReadonly();
  readonly activePath = this.activePathSignal.asReadonly();
  readonly activeFile = this.activeFileSignal.asReadonly();
  readonly mode = this.modeSignal.asReadonly();

  constructor() {
    // Listen to route changes and update state
    this.router.events
      .pipe(filter((event) => event instanceof NavigationEnd))
      .subscribe(() => {
        this.updateStateFromRoute();
      });

    // Initialize from current route
    effect(() => {
      if (!this.initialized) {
        this.updateStateFromRoute();
        this.initialized = true;
      }
    });
  }

  navigate(root: string, dirPath?: string | null, file?: string | null): void {
    const normalizedRoot = root?.trim();
    if (!normalizedRoot) {
      return;
    }

    this.setState(normalizedRoot, this.normalizePath(dirPath), this.normalizePath(file));

    const targetUrl = this.buildUrl(normalizedRoot, dirPath, file);
    void this.router.navigateByUrl(targetUrl).catch(() => {});
  }

  refresh(): void {
    this.updateStateFromRoute();
  }

  private updateStateFromRoute(): void {
    const urlTree = this.router.parseUrl(this.router.url);
    const rootSegments = urlTree.root.children['primary']?.segments ?? [];
    const root = rootSegments.length > 0 ? this.decodeSegment(rootSegments[0].path) : '';

    const queryPath = this.normalizePath(urlTree.queryParams['path']);
    const queryFile = this.normalizePath(urlTree.queryParams['file']);
    if (queryPath !== null || queryFile !== null) {
      this.setState(root || 'plans', queryPath, queryFile);
      return;
    }

    if (!root) {
      this.setState('plans', null, null);
      return;
    }

    const segments = rootSegments.map((segment) => this.decodeSegment(segment.path));

    let dirPath: string | null = null;
    let file: string | null = null;
    let index = 1;

    while (index < segments.length) {
      const marker = segments[index];
      if (marker === 'path' && index + 1 < segments.length) {
        dirPath = this.decodeSegment(segments[index + 1]);
        index += 2;
        continue;
      }
      if (marker === 'file' && index + 1 < segments.length) {
        file = this.decodeSegment(segments[index + 1]);
        index += 2;
        continue;
      }
      index += 1;
    }

    this.setState(root, dirPath, file);
  }

  private buildUrl(root: string, dirPath?: string | null, file?: string | null): string {
    const queryParams: Record<string, string> = {};
    const normalizedPath = this.normalizePath(dirPath);
    if (normalizedPath) {
      queryParams['path'] = normalizedPath;
    }
    const normalizedFile = this.normalizePath(file);
    if (normalizedFile) {
      queryParams['file'] = normalizedFile;
    }

    const tree = this.router.createUrlTree([`/${root}`], { queryParams });
    return this.router.serializeUrl(tree);
  }

  private setState(root: string | null, dirPath: string | null, file: string | null): void {
    this.activeRootSignal.set(root);
    this.activePathSignal.set(dirPath);
    this.activeFileSignal.set(file);
    this.modeSignal.set(file ? 'file' : 'hub');
  }

  private normalizePath(value?: string | null): string | null {
    if (!value) {
      return null;
    }
    return value.length === 0 ? null : value;
  }

  private decodeSegment(segment: string): string {
    try {
      return decodeURIComponent(segment);
    } catch {
      return segment;
    }
  }
}
