import { ChangeDetectorRef, Component, computed, effect, inject, input, output, signal } from '@angular/core';
import { DomSanitizer, type SafeHtml } from '@angular/platform-browser';
import { SelectedStageStore } from '../selected-stage.store';
import type { WorkflowDisplayGraph, WorkflowDisplayGraphError, WorkflowDisplayGraphNode } from '../workflow.types';

/**
 * Render the workflow compiler's Mermaid topology, with a compact, keyboard
 * accessible stage picker below it. The picker deliberately owns selection:
 * Mermaid SVG is presentation, rather than a second, less accessible control.
 */
@Component({
  selector: 'ralph-workflow-graph',
  standalone: true,
  template: `
    @if (error(); as err) {
      <div class="graph-error" data-testid="workflow-graph-error" role="alert">
        <p class="error-title">{{ err.message }}</p>
        <p class="error-code">{{ err.code }}</p>
        @if (err.sourcePath) {
          <p class="error-source">
            Source: <a [href]="sourceHref(err)" data-testid="workflow-graph-source-link">{{ err.sourcePath }}</a>
            @if (err.sourceKind) { <span class="muted">({{ err.sourceKind }})</span> }
            @if (err.line != null) { <span class="muted"> line {{ err.line }}</span> }
          </p>
        }
        <pre class="diagnostics" data-testid="workflow-graph-diagnostics">{{ err.diagnostics }}</pre>
      </div>
    } @else if (graph(); as g) {
      <div class="graph" data-testid="workflow-display-graph" [attr.data-workflow-id]="g.workflowId" [attr.data-mode]="g.mode">
        <div class="graph-summary">
          <div class="meta muted">
            <span>{{ g.sourceKind }}</span><span>{{ g.mode }}</span>
            @if (g.maxReworkIterations != null) { <span>rework x{{ g.maxReworkIterations }}</span> }
            <span>{{ g.nodes.length }} stages · {{ g.edges.length }} connections</span>
          </div>
        </div>

        <div class="diagram hub-nested-panel" data-testid="workflow-mermaid-graph" [class.pending]="!mermaidSvg()">
          @if (mermaidSvg(); as svg) {
            <div class="svg" [innerHTML]="svg"></div>
          } @else {
            <span class="muted">Rendering workflow map…</span>
          }
        </div>

        <div class="stage-picker" aria-label="Workflow stages">
          @for (node of g.nodes; track node.id) {
            <button type="button" class="node" [class.selected]="selectedId() === node.id" [class.derived]="!node.authored"
              [class.supervisor]="isSupervisor(node)" [attr.data-testid]="'graph-node'" [attr.data-node-id]="node.id"
              [attr.data-node-kind]="node.kind" (click)="select(node)">
              <span class="node-id">{{ node.id }}</span><span class="node-kind">{{ node.kind }}</span>
            </button>
          }
        </div>
      </div>
    } @else {
      <p class="muted" data-testid="workflow-graph-missing">Graph data was not returned for this workflow.</p>
    }
  `,
  styles: `
    .graph {
      display: flex;
      flex-direction: column;
      gap: var(--space-3);
      min-width: 0;
    }
    .graph-summary {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: var(--space-2);
    }
    .meta {
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-2) var(--space-3);
      font-size: var(--font-size-xs);
    }
    .muted {
      color: var(--text-muted);
    }
    .diagram {
      display: grid;
      place-items: center;
      min-height: 16rem;
      max-height: 38rem;
      min-width: 0;
      max-width: 100%;
      overflow: auto;
      padding: var(--space-3);
      margin: 0;
    }
    .diagram.pending {
      min-height: 12rem;
    }
    .svg {
      width: 100%;
      min-width: 0;
      max-width: 100%;
      overflow: auto;
    }
    :host ::ng-deep .svg svg {
      display: block;
      width: auto;
      height: auto;
      min-width: 0;
      max-width: 100%;
      max-height: 30rem;
      margin: 0 auto;
    }
    .stage-picker {
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-2);
      min-width: 0;
    }
    .node {
      display: inline-flex;
      align-items: baseline;
      gap: 0.35rem;
      min-height: var(--control-height);
      padding: 0.35rem 0.65rem;
      border: 1.5px solid var(--control-border);
      border-radius: var(--radius-md);
      background: var(--control-bg);
      color: var(--text-primary);
      cursor: pointer;
      text-align: left;
      transition: border-color 0.15s ease, background 0.15s ease, box-shadow 0.15s ease;
    }
    .node:hover {
      border-color: var(--ion-color-step-300, #6e7681);
      background: var(--control-bg-hover);
    }
    .node.selected {
      border-color: var(--accent);
      box-shadow: 0 0 0 1px color-mix(in srgb, var(--accent) 45%, transparent);
      background: var(--control-bg-hover);
    }
    .node.derived {
      border-style: dashed;
    }
    .node.supervisor {
      color: var(--accent-active);
    }
    .node-id {
      font-family: var(--monospace-font);
      font-weight: 600;
      font-size: 0.78rem;
    }
    .node-kind {
      color: var(--text-muted);
      font-size: 0.68rem;
      text-transform: lowercase;
    }
    .graph-error {
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
      padding: var(--space-3);
      border: 1px solid var(--danger);
      border-radius: var(--radius-md);
    }
    .error-title {
      margin: 0;
      font-weight: 600;
    }
    .error-code,
    .error-source {
      margin: 0;
      font-size: var(--font-size-sm);
    }
    .diagnostics {
      margin: 0;
      padding: var(--space-2);
      overflow: auto;
      max-height: 12rem;
      font-size: var(--font-size-xs);
      background: var(--surface-sunken, rgba(0, 0, 0, 0.2));
      border-radius: var(--radius-sm);
    }
    @media (max-width: 640px) {
      .diagram {
        min-height: 12rem;
        padding: var(--space-2);
      }
      :host ::ng-deep .svg svg {
        max-height: 24rem;
      }
    }
  `,
})
export class WorkflowGraphComponent {
  private readonly selectedStage = inject(SelectedStageStore);
  private readonly sanitizer = inject(DomSanitizer);
  private readonly cdr = inject(ChangeDetectorRef);
  private mermaidImportPromise: Promise<MermaidClient | null> | null = null;

  readonly graph = input<WorkflowDisplayGraph | null>(null);
  /** CLI-generated Mermaid source; falls back to the normalized display graph. */
  readonly mermaid = input('');
  readonly error = input<WorkflowDisplayGraphError | null>(null);
  readonly stageSelected = output<string>();
  readonly mermaidSvg = signal<SafeHtml | null>(null);

  readonly selectedId = computed(() => {
    const g = this.graph();
    return g && this.selectedStage.workflowId() === g.workflowId ? this.selectedStage.stageId() : null;
  });

  constructor() {
    effect(() => {
      const graph = this.graph();
      const source = this.mermaid().trim() || (graph ? buildMermaid(graph) : '');
      this.mermaidSvg.set(null);
      if (source) void this.renderMermaid(source);
    });
  }

  select(node: WorkflowDisplayGraphNode): void {
    const g = this.graph();
    if (!g) return;
    this.selectedStage.select(g.workflowId, node.id);
    this.stageSelected.emit(node.id);
  }

  isSupervisor(node: WorkflowDisplayGraphNode): boolean {
    return ['gate', 'approval', 'integrate', 'join', 'checkpoint', 'router', 'input', 'consensus'].includes(node.kind);
  }

  sourceHref(err: WorkflowDisplayGraphError): string { return err.sourcePath?.startsWith('/') ? `file://${err.sourcePath}` : (err.sourcePath ?? '#'); }

  private async renderMermaid(source: string): Promise<void> {
    if (typeof document === 'undefined' || !document.body) return;
    const client = await this.loadMermaidClient();
    if (typeof document === 'undefined' || !document.body) return;
    if (!client || source !== (this.mermaid().trim() || (this.graph() ? buildMermaid(this.graph()!) : ''))) return;
    client.initialize({ startOnLoad: false, theme: document.body.classList.contains('theme-light') ? 'default' : 'dark', securityLevel: 'strict', fontFamily: 'inherit' });
    try {
      const result = await client.render(`workflow-${Math.random().toString(36).slice(2, 10)}`, source);
      this.mermaidSvg.set(this.sanitizer.bypassSecurityTrustHtml(typeof result === 'string' ? result : result.svg));
      this.cdr.markForCheck();
    } catch { this.cdr.markForCheck(); }
  }

  private async loadMermaidClient(): Promise<MermaidClient | null> {
    if (!this.mermaidImportPromise) this.mermaidImportPromise = import('mermaid').then((mod) => (mod.default ?? mod) as MermaidClient).catch(() => null);
    return this.mermaidImportPromise;
  }
}

function buildMermaid(graph: WorkflowDisplayGraph): string {
  const lines = ['flowchart LR'];
  for (const node of graph.nodes) lines.push(`  ${safeId(node.id)}["${node.label.replaceAll('"', '\\"')}"]`);
  for (const edge of graph.edges) lines.push(`  ${safeId(edge.from)} -->${edge.label ? `|${edge.label}|` : ''} ${safeId(edge.to)}`);
  return lines.join('\n');
}
function safeId(id: string): string { return `n_${id.replace(/[^A-Za-z0-9_]/g, '_')}`; }
interface MermaidClient { initialize(options: Record<string, unknown>): void; render(id: string, source: string): Promise<string | { svg: string }>; }
