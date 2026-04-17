import { CommonModule } from '@angular/common';
import { Component, Input, OnInit, effect, inject, signal } from '@angular/core';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { IonSpinner, IonButton } from '@ionic/angular/standalone';
import { Subscription } from 'rxjs';
import { ApiService, FileChunk, MetricsSummary, MetricsSummaryItem } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { PlanLogResolutionService } from '../../services/plan-log-resolution.service';
import { markdownToHtml } from '../../utils/markdown-to-html';
import { sanitizeHtmlDocument } from '../../utils/sanitize-html';
import { formatElapsedSeconds } from '../../utils/format-elapsed';

interface TokenTotals {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
}

@Component({
  selector: 'app-file-viewer',
  standalone: true,
  imports: [CommonModule, IonSpinner, IonButton],
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
  error = signal<string | null>(null);
  isRendered = signal<boolean>(true);
  safeHtml = signal<SafeHtml | null>(null);
  workspaceRoot = signal<string>('');
  planMetrics = signal<MetricsSummaryItem | null>(null);

  private metricsSummary = signal<MetricsSummary | null>(null);

  constructor() {
    // Coalesce root/filePath changes into one load and cancel any in-flight request.
    effect((onCleanup) => {
      const root = this.rootSignal();
      const filePath = this.filePathSignal();

      if (!root || !filePath) {
        this.loadSequence += 1;
        this.loading.set(false);
        this.error.set(null);
        return;
      }

      const subscription = this.loadFile(root, filePath);
      onCleanup(() => subscription.unsubscribe());
    });

    effect(() => {
      this.syncPlanMetrics();
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

    this.api.fetchMetricsSummary().subscribe({
      next: (summary) => {
        this.metricsSummary.set(summary);
        this.syncPlanMetrics();
      },
      error: () => {
        this.metricsSummary.set(null);
        this.planMetrics.set(null);
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

    return this.api.fetchFile(root, filePath).subscribe({
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
      error: () => {
        if (requestToken !== this.loadSequence) {
          return;
        }

        this.error.set('Failed to load file');
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

  isMarkdown(): boolean {
    return this.isMarkdownPath(this.filePathSignal());
  }

  isJson(): boolean {
    const path = this.filePathSignal();
    return path.endsWith('.json') || path.endsWith('.orch.json');
  }

  formatSeconds(value: number): string {
    return formatElapsedSeconds(value);
  }

  formatCompactTokens(value: number): string {
    if (!Number.isFinite(value) || value <= 0) {
      return '--';
    }

    if (value < 10000) {
      return new Intl.NumberFormat().format(Math.round(value));
    }

    return new Intl.NumberFormat(undefined, {
      notation: 'compact',
      maximumFractionDigits: 1,
    }).format(value);
  }

  totalTokensForEntry(entry: TokenTotals): number {
    return (
      entry.input_tokens +
      entry.output_tokens +
      entry.cache_creation_input_tokens +
      entry.cache_read_input_tokens
    );
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
    return this.planLogResolution.resolvePlanDirectory(this.filePathSignal());
  }

  get showViewLogs(): boolean {
    const root = this.rootSignal();
    return (root === 'plans' || root === 'logs') && this.isMarkdown();
  }

  viewLogs(): void {
    const dir = this.planDirectory;
    if (!dir) return;

    this.planLogResolution.resolveLatestLogTarget(dir).subscribe({
      next: (target) => {
        this.nav.navigate('logs', target.directory, target.file);
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

    this.nav.navigate(currentRoot, null, targetPath);
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

  private syncPlanMetrics(): void {
    const summary = this.metricsSummary();
    const fileName = this.filePathSignal().split('/').filter(Boolean).pop() ?? '';
    const planKey = this.stripPlanSuffix(fileName);

    if (!summary || !planKey) {
      this.planMetrics.set(null);
      return;
    }

    this.planMetrics.set(this.findLatestPlanMetrics(summary, planKey));
  }

  private findLatestPlanMetrics(summary: MetricsSummary, planKey: string): MetricsSummaryItem | null {
    const matches = summary.plans.filter((item) => item.plan_key === planKey);
    if (matches.length === 0) {
      return null;
    }
    return matches.reduce((latest, candidate) =>
      this.metricTimestamp(candidate) > this.metricTimestamp(latest) ? candidate : latest,
    );
  }

  private metricTimestamp(item: MetricsSummaryItem): number {
    return this.parseTimestamp(item.ended_at) || this.parseTimestamp(item.started_at);
  }

  private parseTimestamp(value?: string): number {
    if (!value) {
      return 0;
    }
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  private stripPlanSuffix(fileName: string): string {
    if (fileName.endsWith('.mdc')) {
      return fileName.slice(0, -4);
    }
    if (fileName.endsWith('.md')) {
      return fileName.slice(0, -3);
    }
    return fileName;
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
