import { Injectable, signal } from '@angular/core';

function isBrowser(): boolean {
  return typeof window !== 'undefined';
}

@Injectable({
  providedIn: 'root',
})
export class NavService {
  private readonly activeRootSignal = signal<string | null>(null);
  private readonly activePathSignal = signal<string | null>(null);
  private readonly activeFileSignal = signal<string | null>(null);
  private readonly modeSignal = signal<'hub' | 'file'>('hub');

  readonly activeRoot = this.activeRootSignal.asReadonly();
  readonly activePath = this.activePathSignal.asReadonly();
  readonly activeFile = this.activeFileSignal.asReadonly();
  readonly mode = this.modeSignal.asReadonly();

  constructor() {
    if (isBrowser()) {
      this.parseHash();
    }
  }

  navigate(root: string, dirPath?: string, file?: string): void {
    this.activeRootSignal.set(root);
    this.activePathSignal.set(dirPath ?? null);
    this.activeFileSignal.set(file ?? null);
    this.modeSignal.set(file ? 'file' : 'hub');

    const params = new URLSearchParams();
    params.set('root', root);
    if (dirPath) {
      params.set('path', dirPath);
    }
    if (file) {
      params.set('file', file);
    }

    let hash = `#root=${root}`;
    if (dirPath) {
      hash += `&path=${dirPath}`;
    }
    if (file) {
      hash += `&file=${file}`;
    }

    if (isBrowser()) {
      window.location.hash = hash;
    }
  }

  parseHash(): void {
    if (!isBrowser()) {
      return;
    }
    const hash = window.location.hash;
    if (!hash || hash === '#') {
      this.activeRootSignal.set(null);
      this.activePathSignal.set(null);
      this.activeFileSignal.set(null);
      this.modeSignal.set('hub');
      return;
    }

    const searchParams = new URLSearchParams(hash.slice(1));
    const root = searchParams.get('root');
    const path = searchParams.get('path');
    const file = searchParams.get('file');

    this.activeRootSignal.set(root);
    this.activePathSignal.set(path);
    this.activeFileSignal.set(file);
    this.modeSignal.set(file ? 'file' : 'hub');
  }

  refresh(): void {
    this.parseHash();
  }
}
