import { CommonModule } from '@angular/common';
import { Component, Input, inject, signal } from '@angular/core';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { ApiService, FileChunk } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { markdownToHtml } from '../../utils/markdown-to-html';

@Component({
  selector: 'app-file-viewer',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './file-viewer.component.html',
  styleUrls: ['./file-viewer.component.scss'],
})
export class FileViewerComponent {
  private readonly api = inject(ApiService);
  private readonly nav = inject(NavService);
  private readonly sanitizer = inject(DomSanitizer);
  private mermaidImportPromise: Promise<MermaidClient | null> | null = null;

  rootSignal = signal<string>('');
  filePathSignal = signal<string>('');
  content = signal<string>('');
  loading = signal<boolean>(false);
  error = signal<string | null>(null);
  isRendered = signal<boolean>(true);
  safeHtml = signal<SafeHtml | null>(null);

  @Input() set root(value: string) {
    this.rootSignal.set(value);
    this.loadFile(value, this.filePathSignal());
  }

  @Input() set filePath(value: string) {
    this.filePathSignal.set(value);
    this.loadFile(this.rootSignal(), value);
  }

  loadFile(root: string, filePath: string): void {
    if (!root || !filePath) return;

    this.loading.set(true);
    this.error.set(null);

    this.api.fetchFile(root, filePath).subscribe({
      next: (chunk) => {
        this.content.set(chunk.content);
        this.loading.set(false);
        if (this.isMarkdown()) {
          void this.renderMarkdown(chunk.content);
        } else {
          this.safeHtml.set(null);
        }
      },
      error: () => {
        this.error.set('Failed to load file');
        this.loading.set(false);
      },
    });
  }

  toggleView(): void {
    this.isRendered.update((val) => !val);
    if (this.isRendered() && this.isMarkdown()) {
      void this.renderMarkdown(this.content());
    }
  }

  isMarkdown(): boolean {
    const path = this.filePathSignal();
    return path.endsWith('.md') || path.endsWith('.mdc');
  }

  isJson(): boolean {
    const path = this.filePathSignal();
    return path.endsWith('.json') || path.endsWith('.orch.json');
  }

  formatHtml(): string {
    return markdownToHtml(this.content());
  }

  formatJson(): string {
    try {
      return JSON.stringify(JSON.parse(this.content()), null, 2);
    } catch {
      return this.content();
    }
  }

  isPlainText(): boolean {
    return !this.isMarkdown() && !this.isJson();
  }

  get planDirectory(): string | null {
    const path = this.filePathSignal();
    if (!path) return null;
    const parts = path.split('/').filter(Boolean);
    return parts.length > 0 ? parts[0] : null;
  }

  get showViewLogs(): boolean {
    const root = this.rootSignal();
    return (root === 'plans' || root === 'logs') && this.isMarkdown();
  }

  viewLogs(): void {
    const dir = this.planDirectory;
    if (!dir) return;
    this.nav.navigate('logs', dir, null);
  }

  get runSnippet(): string | null {
    const root = this.rootSignal();
    const path = this.filePathSignal();
    const fileName = path.split('/').filter(Boolean).pop() ?? '';
    if (!fileName) return null;
    if ((root === 'plans' || root === 'logs') && path.endsWith('.md')) {
      return `bash $PWD/.ralph/run-plan.sh --plan ${fileName}`;
    }
    if (root === 'orchestration-plans' && path.endsWith('.orch.json')) {
      return `bash $PWD/.ralph/run-orchestration.sh --plan ${fileName}`;
    }
    return null;
  }

  private async renderMarkdown(source: string): Promise<void> {
    if (typeof document === 'undefined') {
      return;
    }

    const html = this.formatHtmlFromSource(source);
    this.safeHtml.set(this.sanitizer.bypassSecurityTrustHtml(html));

    const doc = new DOMParser().parseFromString(html, 'text/html');
    await this.renderMermaidDiagrams(doc);
    this.safeHtml.set(this.sanitizer.bypassSecurityTrustHtml(doc.body.innerHTML));
  }

  private formatHtmlFromSource(source: string): string {
    return markdownToHtml(source);
  }

  private async renderMermaidDiagrams(doc: Document): Promise<void> {
    const mermaidBlocks = Array.from(doc.querySelectorAll('pre > code.language-mermaid'));
    if (mermaidBlocks.length === 0) {
      return;
    }

    const mermaidClient = await this.loadMermaidClient();
    if (!mermaidClient) {
      return;
    }

    this.ensureSvgMeasurementSupport();

    const isLightTheme = typeof document !== 'undefined'
      ? document.body.classList.contains('theme-light')
      : false;

    mermaidClient.initialize({
      startOnLoad: false,
      theme: isLightTheme ? 'default' : 'dark',
      securityLevel: 'loose',
      fontFamily: 'inherit',
    });

    await Promise.all(
      mermaidBlocks.map(async (code) => {
        const diagram = code.textContent?.trim();
        if (!diagram) {
          return;
        }

        const pre = code.parentElement;
        try {
          const renderResult = await mermaidClient.render(
            `mermaid-${Math.random().toString(36).slice(2, 10)}`,
            diagram,
          );
          const svg = typeof renderResult === 'string' ? renderResult : renderResult.svg;
          const container = doc.createElement('div');
          container.classList.add('mermaid');
          container.innerHTML = svg;
          pre?.replaceWith(container);
        } catch {
          const fallback = doc.createElement('div');
          fallback.classList.add('mermaid-error');
          fallback.textContent = 'Mermaid diagram failed to render.';
          pre?.replaceWith(fallback);
        }
      }),
    );
  }

  private async loadMermaidClient(): Promise<MermaidClient | null> {
    if (!this.mermaidImportPromise) {
      this.mermaidImportPromise = import('mermaid')
        .then((mod) => (mod.default ?? mod) as MermaidClient)
        .catch(() => null);
    }
    return this.mermaidImportPromise;
  }

  private ensureSvgMeasurementSupport(): void {
    if (typeof SVGElement === 'undefined') {
      return;
    }

    const proto = SVGElement.prototype as SVGElement & {
      getBBox?: () => DOMRect;
      getComputedTextLength?: () => number;
    };

    if (typeof proto.getBBox !== 'function') {
      proto.getBBox = () =>
        ({
          x: 0,
          y: 0,
          width: 0,
          height: 0,
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          toJSON: () => ({}),
        }) as DOMRect;
    }

    if (typeof proto.getComputedTextLength !== 'function') {
      proto.getComputedTextLength = () => 0;
    }
  }
}

interface MermaidClient {
  initialize(config?: Record<string, unknown>): void;
  render(id: string, definition: string): Promise<{ svg: string } | string>;
}
