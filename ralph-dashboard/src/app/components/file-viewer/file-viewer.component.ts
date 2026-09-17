import { CommonModule } from '@angular/common';
import { Component, Input, OnInit, effect, inject, signal } from '@angular/core';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { IonSpinner, IonButton } from '@ionic/angular/standalone';
import { Subscription } from 'rxjs';
import { ApiService, FileChunk } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { PlanLogResolutionService } from '../../services/plan-log-resolution.service';
import { markdownToHtml } from '../../utils/markdown-to-html';
import { sanitizeHtmlDocument } from '../../utils/sanitize-html';
import { ResourceError } from '../../../shared/resource-error';
import { ErrorModalComponent } from '../error-modal/error-modal.component';

@Component({
  selector: 'app-file-viewer',
  standalone: true,
  imports: [CommonModule, IonSpinner, IonButton, ErrorModalComponent],
  templateUrl: './file-viewer.component.html',
  styleUrls: ['./file-viewer.component.scss'],
})
export class FileViewerComponent implements OnInit {
  private readonly api = inject(ApiService);
  private readonly nav = inject(NavService);
  private readonly sanitizer = inject(DomSanitizer);
  private readonly planLogResolution = inject(PlanLogResolutionService);
  private mermaidImportPromise: Promise<MermaidClient | null> | null = null;
  private loadSequence = 0;

  rootSignal = signal<string>('');
  filePathSignal = signal<string>('');
  content = signal<string>('');
  loading = signal<boolean>(false);
  error = signal<ResourceError | null>(null);
  isRendered = signal<boolean>(true);
  safeHtml = signal<SafeHtml | null>(null);
  workspaceRoot = signal<string>('');

  constructor() {
    // Coalesce root/filePath changes into one load and cancel any in-flight request.
    effect((onCleanup) => {
      const root = this.rootSignal();
      const filePath = this.filePathSignal();
      this.nav.activeWorkspaceRoot();
      this.nav.activeProjectRoot();

      if (!root || !filePath) {
        this.loadSequence += 1;
        this.loading.set(false);
        this.error.set(null);
        return;
      }

      const subscription = this.loadFile(root, filePath);
      onCleanup(() => subscription.unsubscribe());
    });
  }

  ngOnInit(): void {
    this.api.fetchWorkspace().subscribe({
      next: (workspace) => {
        this.workspaceRoot.set(workspace.root);
      },
      error: () => {
        // Fallback to empty string, component will still work
        this.workspaceRoot.set('');
      },
    });
  }

  @Input() set root(value: string) {
    this.rootSignal.set(value);
  }

  @Input() set filePath(value: string) {
    this.filePathSignal.set(value);
  }

  private loadFile(root: string, filePath: string): Subscription {
    const requestToken = ++this.loadSequence;
    const markdownFile = this.isMarkdownPath(filePath);

    this.loading.set(true);
    this.error.set(null);

    return this.api
      .fetchFile(
        root,
        filePath,
        0,
        this.nav.activeWorkspaceRoot() ?? undefined,
        this.nav.activeProjectRoot() ?? undefined,
      )
      .subscribe({
        next: (chunk) => {
          if (requestToken !== this.loadSequence) {
            return;
          }

          this.content.set(chunk.content);
          if (markdownFile) {
            void this.renderMarkdown(chunk.content, requestToken, true);
          } else {
            this.safeHtml.set(null);
            this.loading.set(false);
          }
        },
        error: (err) => {
          if (requestToken !== this.loadSequence) {
            return;
          }

          // Check if error is a ResourceError object
          if (err && typeof err === 'object' && 'code' in err && 'title' in err) {
            this.error.set(err as ResourceError);
          } else {
            // Fallback for unexpected error types
            this.error.set({
              code: 'UNKNOWN',
              message: 'Failed to load file',
              title: 'Error Loading File',
              explanation: 'An unexpected error occurred while loading the file.',
              recoverable: true,
              suggestedActions: ['RETRY', 'RETURN_TO_PLANS'],
            });
          }
          this.loading.set(false);
        },
      });
  }

  toggleView(): void {
    this.isRendered.update((val) => !val);
    if (this.isRendered() && this.isMarkdown()) {
      void this.renderMarkdown(this.content(), this.loadSequence);
    }
  }

  performErrorAction(action: string): void {
    switch (action) {
      case 'RETRY':
        // Retry loading the file
        const subscription = this.loadFile(this.rootSignal(), this.filePathSignal());
        subscription.unsubscribe();
        break;
      case 'REFRESH_INDEX':
        // Trigger index refresh - navigate to plans to refresh
        this.nav.navigate('plans');
        break;
      case 'RETURN_TO_PLANS':
        this.nav.navigate('plans');
        break;
      case 'SELECT_PROJECT':
        // Navigate to plans to allow project selection
        this.nav.navigate('plans');
        break;
    }
  }

  isMarkdown(): boolean {
    return this.isMarkdownPath(this.filePathSignal());
  }

  isJson(): boolean {
    const path = this.filePathSignal();
    return (
      path.endsWith('.json') ||
      path.endsWith('.orch.json') ||
      path.endsWith('.ndjson') ||
      path.endsWith('.jsonl')
    );
  }

  formatHtml(): string {
    return markdownToHtml(this.content());
  }

  formatJson(): string {
    if (this.isStructuredJsonStream()) {
      return this.formatStructuredJsonStream(this.content());
    }

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
    return this.planLogResolution.resolvePlanDirectory(this.filePathSignal());
  }

  get showViewLogs(): boolean {
    const root = this.rootSignal();
    return (root === 'plans' || root === 'logs') && this.isMarkdown();
  }

  viewLogs(): void {
    const dir = this.planDirectory;
    if (!dir) return;

    const ws = this.nav.activeWorkspaceRoot() ?? undefined;
    this.planLogResolution.resolveLatestLogTarget(dir, ws).subscribe({
      next: (target) => {
        if (!target.file) {
          return;
        }
        const dirArg = target.directory ?? '';
        this.nav.navigate('logs', dirArg, target.file, ws ?? null, this.nav.activeProjectRoot());
      },
    });
  }

  handleContentClick(event: MouseEvent): void {
    const anchor = (event.target as HTMLElement).closest('a');
    if (!anchor) return;

    const href = anchor.getAttribute('href');
    if (
      !href ||
      href.startsWith('http://') ||
      href.startsWith('https://') ||
      href.startsWith('//') ||
      href.startsWith('mailto:')
    ) {
      return;
    }

    event.preventDefault();

    // Strip fragment
    const [filePart] = href.split('#');
    if (!filePart) return;

    const currentFile = this.filePathSignal();
    const currentRoot = this.rootSignal();

    // Resolve the relative path against the current file's directory
    const currentDir = currentFile.split('/').filter(Boolean).slice(0, -1);
    const targetParts = filePart.startsWith('/')
      ? filePart.slice(1).split('/')
      : [...currentDir, ...filePart.split('/')];

    const resolved: string[] = [];
    for (const part of targetParts) {
      if (part === '..') {
        resolved.pop();
      } else if (part !== '.' && part !== '') {
        resolved.push(part);
      }
    }

    const targetPath = resolved.join('/');
    if (!targetPath) return;

    this.nav.navigate(
      currentRoot,
      null,
      targetPath,
      this.nav.activeWorkspaceRoot(),
      this.nav.activeProjectRoot(),
    );
  }

  get runSnippet(): string | null {
    const root = this.rootSignal();
    const path = this.filePathSignal();
    const fileName = path.split('/').filter(Boolean).pop() ?? '';
    const workspaceRoot = this.workspaceRoot();
    if (!fileName) return null;
    if ((root === 'plans' || root === 'logs') && path.endsWith('.md')) {
      const wsPath = workspaceRoot || '$PWD';
      return `bash ${wsPath}/.ralph/run-plan.sh --plan ${fileName}`;
    }
    if (root === 'orchestration-plans' && path.endsWith('.orch.json')) {
      const wsPath = workspaceRoot || '$PWD';
      return `bash ${wsPath}/.ralph/run-orchestration.sh --plan ${fileName}`;
    }
    return null;
  }

  private isMarkdownPath(path: string): boolean {
    return path.endsWith('.md') || path.endsWith('.mdc');
  }

  private isStructuredJsonStream(): boolean {
    const path = this.filePathSignal();
    return path.endsWith('.ndjson') || path.endsWith('.jsonl');
  }

  private formatStructuredJsonStream(source: string): string {
    return source
      .split(/\r?\n/)
      .map((line) => this.formatStructuredJsonLine(line))
      .join('\n');
  }

  private formatStructuredJsonLine(line: string): string {
    const trimmed = line.trim();
    if (!trimmed) {
      return '';
    }

    try {
      const parsed = JSON.parse(trimmed);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return trimmed;
      }

      return this.formatStructuredJsonRecord(parsed as Record<string, unknown>);
    } catch {
      return line;
    }
  }

  private formatStructuredJsonRecord(record: Record<string, unknown>): string {
    const type = this.readStringField(record, 'type');
    const subtype = this.readStringField(record, 'subtype');
    const headline = this.formatStreamHeadline(type, subtype);
    const details = this.formatStreamDetails(record, ['type', 'subtype']);

    if (!headline) {
      return details || JSON.stringify(record);
    }

    return details ? `${headline} (${details})` : headline;
  }

  private formatStreamHeadline(type?: string, subtype?: string): string {
    if (!type) {
      return '';
    }

    const normalizedType = this.humanizeStreamToken(type);
    if (!subtype) {
      return normalizedType;
    }

    return `${normalizedType} ${this.humanizeStreamToken(subtype)}`;
  }

  private formatStreamDetails(record: Record<string, unknown>, excludedKeys: string[]): string {
    const details: string[] = [];
    const excluded = new Set(excludedKeys);

    for (const [key, value] of Object.entries(record)) {
      if (excluded.has(key) || value === undefined || value === null) {
        continue;
      }

      if (key === 'timestamp_ms' && typeof value === 'number' && Number.isFinite(value)) {
        details.push(`timestamp=${this.formatStreamTimestamp(value)}`);
        continue;
      }

      if (key === 'session_id' || key === 'attempt' || key === 'checkpoint_turn_count') {
        details.push(`${this.humanizeStreamToken(key)}=${this.formatStreamValue(value)}`);
        continue;
      }

      if (key === 'is_resume' && value === true) {
        details.push('is_resume=true');
        continue;
      }

      if (key === 'duration_ms' || key === 'is_error') {
        details.push(`${this.humanizeStreamToken(key)}=${this.formatStreamValue(value)}`);
      }
    }

    return details.join(', ');
  }

  private formatStreamTimestamp(value: number): string {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return String(value);
    }

    try {
      return date.toISOString();
    } catch {
      return String(value);
    }
  }

  private formatStreamValue(value: unknown): string {
    if (typeof value === 'string') {
      return value;
    }

    if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
      return String(value);
    }

    if (Array.isArray(value)) {
      return `[${value.map((item) => this.formatStreamValue(item)).join(', ')}]`;
    }

    if (value && typeof value === 'object') {
      try {
        return JSON.stringify(value);
      } catch {
        return '[object]';
      }
    }

    return String(value);
  }

  private readStringField(record: Record<string, unknown>, key: string): string | undefined {
    const value = record[key];
    return typeof value === 'string' && value.trim() ? value.trim() : undefined;
  }

  private humanizeStreamToken(value: string): string {
    return value.replace(/[_-]+/g, ' ').trim();
  }

  private async renderMarkdown(source: string, requestToken: number, finalizeLoad = false): Promise<void> {
    if (typeof document === 'undefined') {
      if (finalizeLoad && requestToken === this.loadSequence) {
        this.loading.set(false);
      }
      return;
    }

    const html = this.formatHtmlFromSource(source);
    const doc = new DOMParser().parseFromString(html, 'text/html');
    sanitizeHtmlDocument(doc.body);
    if (requestToken !== this.loadSequence) {
      return;
    }
    this.safeHtml.set(this.sanitizer.bypassSecurityTrustHtml(doc.body.innerHTML));

    await this.renderMermaidDiagrams(doc);
    if (requestToken !== this.loadSequence) {
      return;
    }
    sanitizeHtmlDocument(doc.body);
    // Angular's HTML sanitizer strips Mermaid SVG entirely, so we clean the DOM
    // ourselves and then trust the result to preserve the rendered diagram.
    this.safeHtml.set(this.sanitizer.bypassSecurityTrustHtml(doc.body.innerHTML));
    if (finalizeLoad && requestToken === this.loadSequence) {
      this.loading.set(false);
    }
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
      securityLevel: 'strict',
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

  // sanitizer helper replaced with shared implementation
}

interface MermaidClient {
  initialize(config?: Record<string, unknown>): void;
  render(id: string, definition: string): Promise<{ svg: string } | string>;
}
