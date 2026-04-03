import { Injectable, inject, signal } from '@angular/core';
import { NavigationEnd, Router, UrlSegment } from '@angular/router';
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

  readonly activeRoot = this.activeRootSignal.asReadonly();
  readonly activePath = this.activePathSignal.asReadonly();
  readonly activeFile = this.activeFileSignal.asReadonly();
  readonly mode = this.modeSignal.asReadonly();

  navigate(root: string, dirPath?: string | null, file?: string | null): void {
    const normalizedRoot = root?.trim();
    if (!normalizedRoot) {
      return;
    }

    const targetUrl = this.buildUrl(normalizedRoot, dirPath, file);
    this.setState(normalizedRoot, this.normalizePath(dirPath), this.normalizePath(file));
    void this.router.navigateByUrl(targetUrl).catch(() => {});
  }

  refresh(): void {
    this.updateStateFromUrl(this.router.url);
  }

  private buildUrl(root: string, dirPath?: string | null, file?: string | null): string {
    const segments = [encodeURIComponent(root)];
    const normalizedPath = this.normalizePath(dirPath);
    if (normalizedPath) {
      segments.push('path', encodeURIComponent(normalizedPath));
    }
    const normalizedFile = this.normalizePath(file);
    if (normalizedFile) {
      segments.push('file', encodeURIComponent(normalizedFile));
    }

    return `/${segments.join('/')}`;
  }

  private updateStateFromUrl(url: string): void {
    if (!url || url === '/') {
      this.resetState();
      return;
    }

    const tree = this.router.parseUrl(url);
    const segments = tree.root.children['primary']?.segments ?? [];
    if (segments.length === 0) {
      this.resetState();
      return;
    }

    const rootSegment = segments[0];
    const root = rootSegment?.path ?? null;
    if (!root) {
      this.resetState();
      return;
    }

    let dirPath: string | null = null;
    let file: string | null = null;
    let index = 1;

    while (index < segments.length) {
      const marker = segments[index].path;
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

  private resetState(): void {
    this.activeRootSignal.set(null);
    this.activePathSignal.set(null);
    this.activeFileSignal.set(null);
    this.modeSignal.set('hub');
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

  private decodeSegment(segment: UrlSegment): string {
    try {
      return decodeURIComponent(segment.path);
    } catch {
      return segment.path;
    }
  }
}
