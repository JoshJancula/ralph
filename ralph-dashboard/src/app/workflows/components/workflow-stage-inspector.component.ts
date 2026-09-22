import { Component, DestroyRef, OnInit, computed, effect, inject, input, signal } from '@angular/core';
import { DomSanitizer, type SafeHtml } from '@angular/platform-browser';
import { markdownToHtml } from '../../utils/markdown-to-html';
import { sanitizeHtmlDocument } from '../../utils/sanitize-html';
import { SelectedStageStore } from '../selected-stage.store';
import {
  buildStageInspectorView,
  filterSourceLines,
  highlightYamlSource,
} from '../stage-inspector.helpers';
import type { WorkflowDetail } from '../workflow.types';

/**
 * Detail + Source inspector synchronized with the workflow graph via
 * SelectedStageStore. Supervisor nodes render as controls, never as agents.
 */
@Component({
  selector: 'ralph-workflow-stage-inspector',
  standalone: true,
  template: `
    <section class="inspector hub-nested-panel" data-testid="workflow-stage-inspector">
      @if (!view()) {
        <p class="empty muted" data-testid="inspector-empty">Select a stage in the graph to inspect it.</p>
      } @else {
        <header class="head">
          <div class="title-block">
            <h3 class="stage-id" data-testid="inspector-stage-id">{{ view()!.stageId }}</h3>
            <div class="badges">
              @if (view()!.role === 'supervisor') {
                <span class="badge supervisor" data-testid="inspector-role">Supervisor control</span>
              } @else {
                <span class="badge agent" data-testid="inspector-role">Agent stage</span>
              }
              <span class="badge kind" data-testid="inspector-kind">{{ view()!.nodeKind }}</span>
              <span
                class="badge write"
                [class.mutation]="view()!.writeCapability === 'mutation'"
                [class.read-only]="view()!.writeCapability === 'read-only'"
                [class.supervisor-write]="view()!.writeCapability === 'supervisor'"
                data-testid="inspector-write-capability"
              >
                @switch (view()!.writeCapability) {
                  @case ('mutation') {
                    Writes enabled
                  }
                  @case ('read-only') {
                    Read-only
                  }
                  @default {
                    Supervisor (no agent write)
                  }
                }
              </span>
            </div>
          </div>
          <div class="pane-tabs" role="tablist">
            <button
              type="button"
              role="tab"
              class="tab"
              [class.active]="activePane() === 'detail'"
              data-testid="inspector-tab-detail"
              (click)="activePane.set('detail')"
            >
              Detail
            </button>
            <button
              type="button"
              role="tab"
              class="tab"
              [class.active]="activePane() === 'source'"
              data-testid="inspector-tab-source"
              (click)="activePane.set('source')"
            >
              Source
            </button>
          </div>
        </header>

        @if (activePane() === 'detail') {
          <div class="detail-pane" data-testid="inspector-detail-pane">
            <dl class="facts">
              <div>
                <dt>Goal</dt>
                <dd data-testid="inspector-goal">{{ view()!.goal }}</dd>
              </div>
              <div>
                <dt>Dependencies</dt>
                <dd data-testid="inspector-depends">
                  @if (view()!.dependsOn.length === 0) {
                    <span class="muted">none</span>
                  } @else {
                    {{ view()!.dependsOn.join(', ') }}
                  }
                </dd>
              </div>
              <div>
                <dt>Runtime / model</dt>
                <dd data-testid="inspector-routing">
                  {{ view()!.runtime || 'inherit' }} / {{ view()!.model || 'inherit' }}
                </dd>
              </div>
              @if (view()!.workspaceMode) {
                <div>
                  <dt>Workspace</dt>
                  <dd>{{ view()!.workspaceMode }}</dd>
                </div>
              }
              @if (view()!.planFrom || view()!.planRole || view()!.planner) {
                <div>
                  <dt>Plan</dt>
                  <dd data-testid="inspector-plan">
                    @if (view()!.planRole) {
                      <span class="chip">{{ view()!.planRole }}</span>
                    }
                    @if (view()!.planFrom) {
                      <span>from {{ view()!.planFrom }}</span>
                    }
                    @if (view()!.planner?.outputMode) {
                      <span class="muted">({{ view()!.planner!.outputMode }})</span>
                    }
                  </dd>
                </div>
              }
              @if (view()!.gateBehavior; as gate) {
                <div>
                  <dt>Gate behavior</dt>
                  <dd data-testid="inspector-gate-behavior">
                    <span class="chip supervisor-chip">{{ gate.kind }}</span>
                    @if (gate.profile) {
                      <span class="chip">profile: {{ gate.profile }}</span>
                    }
                    @if (gate.question) {
                      <span>{{ gate.question }}</span>
                    }
                    @if (gate.changesTarget) {
                      <span class="chip">changesTarget: {{ gate.changesTarget }}</span>
                    }
                    @if (gate.onExhausted) {
                      <span class="chip">onExhausted: {{ gate.onExhausted }}</span>
                    }
                  </dd>
                </div>
              }
              @if (view()!.rework; as rework) {
                <div>
                  <dt>Rework</dt>
                  <dd data-testid="inspector-rework">
                    @if (rework.loopBackTo) {
                      <span class="chip">loopBackTo: {{ rework.loopBackTo }}</span>
                    }
                    @if (rework.changesTarget) {
                      <span class="chip">changesTarget: {{ rework.changesTarget }}</span>
                    }
                    @if (rework.derivedFrom) {
                      <span class="muted">derived: {{ rework.derivedFrom }}</span>
                    }
                  </dd>
                </div>
              }
            </dl>

            <section class="artifacts">
              <h4>Inputs</h4>
              <ul data-testid="inspector-inputs">
                @for (chip of view()!.inputs; track chip.path) {
                  <li>
                    <code>{{ chip.path }}</code>
                    <span class="chip" [class.required]="chip.status === 'required'" [class.optional]="chip.status === 'optional'">
                      {{ chip.status }}
                    </span>
                  </li>
                } @empty {
                  <li class="muted">No required inputs</li>
                }
              </ul>
              <h4>Outputs</h4>
              <ul data-testid="inspector-outputs">
                @for (chip of view()!.outputs; track chip.path) {
                  <li>
                    <code>{{ chip.path }}</code>
                    <span class="chip" [class.required]="chip.status === 'required'" [class.optional]="chip.status === 'optional'">
                      {{ chip.status }}
                    </span>
                    @if (chip.schema) {
                      <span class="muted schema">{{ chip.schema }}</span>
                    }
                  </li>
                } @empty {
                  <li class="muted">No produced artifacts</li>
                }
              </ul>
            </section>

            @if (view()!.role === 'agent' && view()!.instructionsMarkdown) {
              <section class="instructions" data-testid="inspector-instructions">
                <h4>Instructions</h4>
                <div class="markdown" [innerHTML]="instructionsHtml()"></div>
                @if (view()!.includes.length) {
                  <ul class="includes" data-testid="inspector-includes">
                    @for (frag of view()!.includes; track frag.name) {
                      <li>
                        <a [attr.href]="'#fragment-' + frag.name">{{ frag.name }}</a>
                        @if (frag.body) {
                          <span class="muted">expanded</span>
                        } @else {
                          <span class="muted">linked</span>
                        }
                      </li>
                    }
                  </ul>
                }
                @if (view()!.source) {
                  <p class="offsets muted" data-testid="inspector-source-offsets">
                    Raw source lines {{ view()!.source!.startLine }}–{{ view()!.source!.endLine }}
                  </p>
                }
              </section>
            }
          </div>
        } @else {
          <div class="source-pane" data-testid="inspector-source-pane">
            @if (!view()!.source) {
              <p class="muted" data-testid="inspector-source-missing">
                No authored YAML block for this node (derived or missing from source).
              </p>
            } @else {
              <div class="source-toolbar">
                <label class="search">
                  <span class="sr-only">Search source</span>
                  <input
                    type="search"
                    placeholder="Search stage source"
                    data-testid="inspector-source-search"
                    [value]="sourceQuery()"
                    (input)="sourceQuery.set(($any($event.target).value))"
                  />
                </label>
                <button type="button" class="btn" data-testid="inspector-source-copy" (click)="copySource()">
                  {{ copied() ? 'Copied' : 'Copy' }}
                </button>
                <span class="muted offsets" data-testid="inspector-source-range">
                  lines {{ view()!.source!.startLine }}–{{ view()!.source!.endLine }}
                </span>
              </div>
              <div class="source-scroll" data-testid="inspector-source-scroll">
                <pre class="source-code" data-testid="inspector-source-code"><code [innerHTML]="sourceHtml()"></code></pre>
              </div>
            }
          </div>
        }
      }
    </section>
  `,
  styles: `
    .inspector {
      display: flex;
      flex-direction: column;
      gap: var(--space-3);
      min-width: 0;
    }
    .empty {
      margin: 0;
      padding: var(--space-5) var(--space-3);
      font-size: var(--font-size-sm);
      text-align: center;
    }
    .muted {
      color: var(--text-muted);
    }
    .head {
      display: flex;
      flex-wrap: wrap;
      align-items: flex-start;
      justify-content: space-between;
      gap: 0.75rem;
    }
    .stage-id {
      margin: 0;
      font-family: var(--monospace-font);
      font-size: var(--font-size-lg);
      color: var(--text-primary);
    }
    .badges {
      display: flex;
      flex-wrap: wrap;
      gap: 0.35rem;
      margin-top: 0.35rem;
    }
    .badge,
    .chip {
      display: inline-flex;
      align-items: center;
      font-size: 0.7rem;
      padding: 0.1rem 0.45rem;
      border-radius: 4px;
      border: 1px solid var(--border);
      text-transform: lowercase;
    }
    .badge.supervisor,
    .chip.supervisor-chip {
      color: var(--accent-active);
      border-color: var(--accent);
      text-transform: none;
      font-weight: 600;
    }
    .badge.write {
      text-transform: none;
      font-weight: 700;
      letter-spacing: 0.01em;
    }
    .badge.write.mutation {
      color: #fff;
      background: var(--danger);
      border-color: var(--danger);
    }
    .badge.write.read-only {
      color: var(--text-muted);
    }
    .badge.write.supervisor-write {
      color: var(--accent-active);
      border-color: var(--accent);
    }
    .pane-tabs {
      display: flex;
      gap: 0.15rem;
      padding: 0.15rem;
      border: 1px solid var(--panel-border);
      border-radius: var(--radius-md);
      background: var(--control-bg);
    }
    .tab {
      padding: 0.3rem 0.7rem;
      border: 1px solid transparent;
      border-radius: var(--radius-sm);
      background: transparent;
      color: var(--text-muted);
      cursor: pointer;
      font-size: var(--font-size-sm);
      font-weight: 600;
      min-height: var(--control-height);
      transition: color 0.15s ease, background 0.15s ease, border-color 0.15s ease;
    }
    .tab.active {
      color: var(--text-primary);
      background: var(--control-bg-hover);
      border-color: var(--control-border);
    }
    .facts {
      display: flex;
      flex-direction: column;
      gap: 0.45rem;
      margin: 0;
    }
    .facts > div {
      display: grid;
      grid-template-columns: 7.5rem minmax(0, 1fr);
      gap: 0.4rem;
      font-size: 0.82rem;
      min-width: 0;
    }
    .facts dt {
      color: var(--text-muted);
      margin: 0;
    }
    .facts dd {
      margin: 0;
      display: flex;
      flex-wrap: wrap;
      gap: 0.35rem;
      align-items: center;
      min-width: 0;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    .artifacts h4,
    .instructions h4 {
      margin: 0.75rem 0 0.35rem;
      font-size: var(--font-size-xs);
      font-weight: 700;
      letter-spacing: var(--letter-label);
      text-transform: uppercase;
      color: var(--text-muted);
    }
    .artifacts ul,
    .includes {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: 0.3rem;
      font-size: 0.78rem;
      min-width: 0;
    }
    .artifacts li {
      display: flex;
      flex-wrap: wrap;
      gap: 0.35rem;
      align-items: center;
      min-width: 0;
      overflow-wrap: anywhere;
    }
    .chip.required {
      border-color: var(--accent);
      color: var(--accent-active);
    }
    .chip.optional {
      opacity: 0.8;
    }
    .schema {
      font-size: 0.7rem;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    .markdown {
      font-size: var(--font-size-sm);
      line-height: 1.45;
      max-height: 16rem;
      overflow: auto;
      padding: 0.5rem 0.6rem;
      border: 1px solid var(--panel-border);
      border-radius: var(--radius-md);
      background: var(--code-bg, var(--surface-secondary));
      min-width: 0;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    .offsets {
      font-size: 0.72rem;
      margin: 0.35rem 0 0;
    }
    .source-pane {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      min-width: 0;
    }
    .source-toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
      align-items: center;
      min-width: 0;
    }
    .search {
      flex: 1 1 10rem;
      min-width: 0;
    }
    .search input {
      width: 100%;
      box-sizing: border-box;
      padding: 0.35rem 0.5rem;
      border: 1.5px solid var(--control-border);
      border-radius: var(--radius-md);
      background: var(--control-bg);
      color: var(--text-primary);
      font-size: var(--font-size-sm);
    }
    .source-scroll {
      max-height: 18rem;
      overflow: auto;
      -webkit-overflow-scrolling: touch;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--code-bg, var(--surface-secondary));
      min-width: 0;
      max-width: 100%;
    }
    .source-code {
      margin: 0;
      padding: 0.5rem 0;
      font-family: var(--monospace-font);
      font-size: 0.72rem;
      line-height: 1.45;
      white-space: pre;
      min-width: max-content;
    }
    :host ::ng-deep .source-line {
      display: grid;
      grid-template-columns: 3rem minmax(0, 1fr);
      gap: 0.5rem;
      padding: 0 0.6rem;
      min-width: 0;
    }
    :host ::ng-deep .source-line.match {
      background: color-mix(in srgb, var(--accent) 18%, transparent);
    }
    :host ::ng-deep .line-no {
      color: var(--text-muted);
      text-align: right;
      user-select: none;
    }
    :host ::ng-deep .tok-key {
      color: var(--accent-active);
    }
    :host ::ng-deep .tok-string,
    :host ::ng-deep .tok-block {
      color: #3fb950;
    }
    :host ::ng-deep .tok-literal {
      color: #d2a8ff;
    }
    @media (max-width: 420px) {
      .facts > div {
        grid-template-columns: 1fr;
      }
      .source-scroll {
        max-height: 14rem;
      }
      .markdown {
        max-height: 12rem;
      }
    }
  `,
})
export class WorkflowStageInspectorComponent implements OnInit {
  private readonly store = inject(SelectedStageStore);
  private readonly sanitizer = inject(DomSanitizer);
  private readonly destroyRef = inject(DestroyRef);

  readonly workflow = input.required<WorkflowDetail>();
  /** Optional INCLUDE fragment bodies keyed by name (expanded when present). */
  readonly fragments = input<ReadonlyMap<string, string> | null>(null);

  readonly activePane = signal<'detail' | 'source'>('detail');
  readonly sourceQuery = signal('');
  readonly copied = signal(false);

  readonly view = computed(() => {
    const detail = this.workflow();
    const stageId = this.store.stageId();
    if (!stageId || this.store.workflowId() !== detail.id) {
      return null;
    }
    return buildStageInspectorView(detail, stageId, this.fragments());
  });

  readonly instructionsHtml = computed(() => {
    const markdown = this.view()?.instructionsMarkdown;
    if (!markdown) return this.sanitizer.bypassSecurityTrustHtml('');
    return this.toSafeHtml(markdownToHtml(markdown));
  });

  readonly sourceHtml = computed(() => {
    const view = this.view();
    const source = view?.source;
    if (!source) return this.sanitizer.bypassSecurityTrustHtml('');
    const lines = filterSourceLines(source, this.sourceQuery());
    const html = lines
      .map((line) => {
        const highlighted = highlightYamlSource(line.text);
        const cls = line.match ? 'source-line match' : 'source-line';
        return `<div class="${cls}" data-line="${line.lineNumber}"><span class="line-no">${line.lineNumber}</span><span class="line-text">${highlighted}</span></div>`;
      })
      .join('');
    return this.sanitizer.bypassSecurityTrustHtml(html);
  });

  constructor() {
    effect(() => {
      const detail = this.workflow();
      this.store.bindWorkflow(detail.id);
    });
  }

  ngOnInit(): void {
    this.destroyRef.onDestroy(() => {
      // Keep selection while on the detail page; clear only when the inspector unmounts.
      this.store.clear();
    });
  }

  async copySource(): Promise<void> {
    const text = this.view()?.source?.text;
    if (!text || typeof navigator === 'undefined' || !navigator.clipboard) {
      return;
    }
    try {
      await navigator.clipboard.writeText(text);
      this.copied.set(true);
      window.setTimeout(() => this.copied.set(false), 1500);
    } catch {
      this.copied.set(false);
    }
  }

  private toSafeHtml(html: string): SafeHtml {
    if (typeof DOMParser === 'undefined') {
      return this.sanitizer.bypassSecurityTrustHtml(html);
    }
    const doc = new DOMParser().parseFromString(html, 'text/html');
    sanitizeHtmlDocument(doc.body);
    return this.sanitizer.bypassSecurityTrustHtml(doc.body.innerHTML);
  }
}
