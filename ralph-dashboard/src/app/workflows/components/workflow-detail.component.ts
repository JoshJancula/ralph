import { Component, DestroyRef, OnInit, computed, inject, input, signal, viewChild } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { CapabilitiesService } from '../capabilities.service';
import { ConfirmationDialogService } from '../../services/confirmation-dialog.service';
import { SelectedStageStore } from '../selected-stage.store';
import { WorkflowsFacade } from '../workflows.facade';
import { SCOPE_LABEL } from '../workflow-scope.helpers';
import { StartWorkflowDialogComponent } from './start-workflow-dialog.component';
import { WorkflowGraphComponent } from './workflow-graph.component';
import { WorkflowRoutingSectionComponent } from './workflow-routing-section.component';
import { WorkflowRunsComponent } from './workflow-runs.component';
import { WorkflowStageInspectorComponent } from './workflow-stage-inspector.component';
import type { WorkflowDetail, WorkflowScope, WritableWorkflowScope } from '../workflow.types';

/**
 * Ported from trade-beacon's workflow-detail.component.ts. Dropped: pause/
 * resume schedule, archive/revive, reset-to-template, watchlist/portfolio/
 * source summaries, risk badge (see port-design.md "Component decisions").
 * Graph comes from server displayGraph (inspect topology + rework unroll).
 * Stage selection is shared with the inspector via SelectedStageStore.
 */
@Component({
  selector: 'ralph-workflow-detail',
  standalone: true,
  imports: [
    RouterLink,
    WorkflowRunsComponent,
    StartWorkflowDialogComponent,
    WorkflowGraphComponent,
    WorkflowStageInspectorComponent,
  ],
  template: `
    <div class="detail" data-testid="workflow-detail">
      <header class="page-header">
        <a class="back-link" routerLink="/workflows" data-testid="detail-back">All workflows</a>
        <div class="title-bar">
          <div class="title-row">
            <h1 class="name page-title" data-testid="workflow-name">{{ workflow().id }}</h1>
            <span class="scope-badge" [class]="'scope-' + displayScope()" data-testid="workflow-scope">{{ displayScope() }}</span>
            @if (effectiveScope() && effectiveScope() !== workflow().scope) {
              <span class="mode-badge" data-testid="workflow-effective-scope">effective: {{ effectiveScope() }}</span>
            }
            @if (model()?.mode) {
              <span class="mode-badge">{{ model()?.mode }}</span>
            }
          </div>
          <div class="primary-actions">
            @if (capabilities.capabilities().workflowRuns) {
              <button
                type="button"
                class="btn btn-primary"
                data-testid="detail-run-now"
                [disabled]="facade.isTriggering(workflow().id)"
                (click)="startDialog()?.launch()"
              >
                {{ facade.isTriggering(workflow().id) ? 'Starting…' : 'Start' }}
              </button>
            }
          </div>
        </div>
        @if (model()?.overview) {
          <p class="overview page-lede" data-testid="workflow-overview">{{ model()?.overview }}</p>
        }
        <div class="actions secondary-actions">
          @if (workflow().scope === 'bundled') {
            <button type="button" class="btn btn-secondary" data-testid="detail-customize-global" [disabled]="facade.saving()" (click)="customize('global')">
              Customize globally
            </button>
            <button
              type="button"
              class="btn btn-secondary"
              data-testid="detail-customize-project"
              [disabled]="facade.saving() || facade.needsProjectSelection()"
              (click)="customize('project')"
            >
              Customize for this project
            </button>
          } @else {
            <a
              class="btn btn-secondary"
              [routerLink]="['/workflows', workflow().id, 'edit']"
              [queryParams]="editQueryParams()"
              data-testid="detail-edit"
            >
              Edit
            </a>
            @if (hiddenGlobalLayer() && workflow().scope !== 'global') {
              <a
                class="btn btn-secondary"
                [routerLink]="['/workflows', workflow().id, 'edit']"
                [queryParams]="{ scope: 'global' }"
                data-testid="detail-edit-global"
              >
                Edit global layer
              </a>
            }
            @if (canDeleteOverride()) {
              <button type="button" class="btn btn-danger" data-testid="detail-delete-override" (click)="deleteOverride()">
                Delete {{ workflow().scope }} override
              </button>
            }
          }
        </div>
      </header>

      @if (capabilities.capabilities().workflowRuns) {
        <ralph-start-workflow-dialog [workflowId]="workflow().id" />
      }

      <div class="origin-context" data-testid="workflow-origin">
        <span>Definition origin</span>
        @if (workflow().origin?.projectRoot; as projectRoot) {
          <strong>Project override</strong>
          <code title="{{ projectRoot }}">{{ projectRoot }}</code>
        } @else if (workflow().scope === 'global') {
          <strong>Global Ralph definition</strong>
          @if (workflow().origin?.sourcePath; as sourcePath) { <code title="{{ sourcePath }}">{{ sourcePath }}</code> }
        } @else {
          <strong>Bundled framework definition</strong>
          @if (workflow().origin?.sourcePath; as sourcePath) { <code title="{{ sourcePath }}">{{ sourcePath }}</code> }
        }
      </div>

      @if (workflow().scope === 'bundled') {
        <p class="scope-note" data-testid="detail-bundled-precedence">
          Project overrides beat global copies, which beat bundled defaults. Customize globally to reuse one definition across projects, or customize for this project for a local override only.
        </p>
      }

      @if (workflow().shadowedBy; as shadow) {
        <p class="scope-note scope-warn" data-testid="detail-shadowed-note">
          This {{ workflow().scope }} layer is hidden at run time. The effective winner is {{ shadow.scope }}.
        </p>
      }

      @if (availableLayers().length > 1) {
        <section class="scope-layers" data-testid="detail-scope-layers" aria-label="Which definition copy to view">
          <div class="scope-layers-copy">
            <h3 class="scope-layers-title">View definition copy</h3>
            <p class="scope-layers-hint">
              The same workflow id can exist as a project override, a global copy, and the bundled default. This switches which file you are inspecting — it does not change which copy runs.
            </p>
          </div>
          <div class="scope-layer-toggle" role="radiogroup" aria-label="Definition copy">
            @for (layer of availableLayers(); track layer.scope) {
              <button
                type="button"
                role="radio"
                class="layer-btn"
                [class.active]="layer.scope === workflow().scope"
                [attr.aria-checked]="layer.scope === workflow().scope"
                [attr.data-testid]="'detail-scope-' + layer.scope"
                (click)="openScope(layer.scope)"
              >
                {{ scopeLabel(layer.scope) }}
              </button>
            }
          </div>
        </section>
      }

      @if (!model()) {
        <p class="raw-mode-note" data-testid="workflow-raw-mode-note">
          This file uses frontmatter keys outside the studio's structured-edit subset
          @if (workflow().unsupportedKeys?.length) {
            ({{ workflow().unsupportedKeys!.join(', ') }})
          }
          — open Edit for the raw-frontmatter editor.
        </p>
      }

      @if (model(); as m) {
        <section class="defaults surface-card" aria-label="Workflow defaults">
          <div><span class="label">Runtime / model</span><strong>{{ m.defaultsRuntime || 'inherit' }} / {{ m.defaultsModel || 'inherit' }}</strong></div>
          <div><span class="label">Max parallel</span><strong>{{ m.maxParallel ?? '—' }}</strong></div>
          <div><span class="label">Max rework</span><strong>{{ m.maxReworkIterations ?? '—' }}</strong></div>
          @if (workflow().scope !== 'bundled') {
            <a class="btn btn-ghost defaults-action" [routerLink]="['/workflows', workflow().id, 'edit']" [queryParams]="editQueryParams()">Edit configuration</a>
          }
        </section>

        <section class="stages" data-testid="workflow-stages">
          <h3>Stages ({{ m.stages.length }})</h3>
          <ul>
            @for (stage of m.stages; track stage.id) {
              <li>
                <button
                  type="button"
                  class="stage-pick"
                  [class.selected]="isStageSelected(stage.id)"
                  [attr.data-testid]="'stage-pick-' + stage.id"
                  (click)="selectStage(stage.id)"
                >
                  <span class="stage-id">{{ stage.id }}</span>
                  @if (stage.kind === 'supervisor') {
                    <span class="stage-type">{{ stage.type }}</span>
                  }
                  @if (stage.dependsOn.length > 0) {
                    <span class="stage-deps">depends on: {{ stage.dependsOn.join(', ') }}</span>
                  }
                </button>
              </li>
            }
          </ul>
        </section>
      }

      <section class="graph-inspector" data-testid="workflow-graph-inspector">
        <div class="graph-head">
          <h3>Graph</h3>
          <button type="button" class="btn btn-ghost" data-testid="toggle-raw" (click)="showRaw.set(!showRaw())">
            {{ showRaw() ? 'Hide full file' : 'Show full file' }}
          </button>
        </div>
        @if (showRaw()) {
          <pre class="raw" data-testid="workflow-raw">{{ workflow().raw }}</pre>
        }
        <div class="graph-layout">
          <ralph-workflow-graph
            [graph]="workflow().displayGraph ?? null"
            [mermaid]="workflow().mermaid"
            [error]="workflow().graphError ?? null"
          />
          <aside class="stage-details" aria-label="Selected stage details">
            <div class="stage-details-title">
              <span>Stage details</span>
              <span class="muted">Select a stage in the map</span>
            </div>
            <ralph-workflow-stage-inspector [workflow]="workflow()" />
          </aside>
        </div>
      </section>

      <ralph-workflow-runs [runs]="facade.runs()" [loading]="facade.runsLoading()" />
    </div>
  `,
  styles: `
    .detail {
      display: flex;
      flex-direction: column;
      gap: var(--space-4);
      width: 100%;
      min-width: 0;
      padding-bottom: calc(var(--space-6) + var(--fab-clearance, 4.5rem));
    }
    .page-header {
      display: flex;
      flex-direction: column;
      gap: var(--space-3);
      margin-bottom: 0;
    }
    .title-bar {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: var(--space-4);
    }
    .primary-actions,
    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-2);
    }
    .primary-actions .btn-primary {
      min-width: 6.5rem;
    }
    .secondary-actions {
      padding-top: var(--space-1);
    }
    .title-row {
      display: flex;
      align-items: center;
      gap: var(--space-2);
      flex-wrap: wrap;
      min-width: 0;
    }
    .name {
      margin: 0;
      font-family: var(--monospace-font);
      overflow-wrap: anywhere;
    }
    .origin-context {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: var(--space-2);
      padding: var(--space-2) var(--space-3);
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      background: var(--surface);
      color: var(--text-muted);
      font-size: var(--font-size-xs);
    }
    .origin-context strong { color: var(--text-primary); }
    .origin-context code {
      max-width: min(100%, 48rem);
      overflow: hidden;
      font-family: var(--monospace-font);
      font-size: 0.72rem;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .overview {
      color: var(--text-muted);
      margin: 0;
      max-width: 46rem;
    }
    .scope-note {
      margin: 0;
      font-size: var(--font-size-sm);
      color: var(--text-muted);
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      padding: var(--space-2) var(--space-3);
    }
    .scope-warn {
      border-color: var(--danger);
      color: var(--danger);
    }
    .scope-layers {
      display: grid;
      gap: var(--space-2);
      padding: var(--space-3);
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      background: var(--surface);
    }
    .scope-layers-copy {
      display: grid;
      gap: 0.25rem;
    }
    .scope-layers-title {
      margin: 0;
      font-size: var(--font-size-sm);
      font-weight: 600;
      color: var(--text-primary);
    }
    .scope-layers-hint {
      margin: 0;
      max-width: 42rem;
      color: var(--text-muted);
      font-size: var(--font-size-xs);
      line-height: 1.45;
    }
    .scope-layer-toggle {
      display: inline-flex;
      flex-wrap: wrap;
      gap: 0.2rem;
      width: fit-content;
      max-width: 100%;
      padding: 0.2rem;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: color-mix(in srgb, var(--background) 70%, var(--surface));
    }
    .layer-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: var(--touch-target-min, 44px);
      padding: 0.35rem 0.85rem;
      border: 0;
      border-radius: 6px;
      background: transparent;
      color: var(--text-muted);
      cursor: pointer;
      font-size: var(--font-size-sm);
      font-weight: 600;
    }
    .layer-btn:focus-visible {
      outline: var(--focus-ring-width) solid var(--focus-ring-color);
      outline-offset: var(--focus-ring-offset);
    }
    .layer-btn:hover:not(.active) {
      color: var(--text-primary);
      background: var(--surface-hover);
    }
    .layer-btn.active {
      background: var(--accent);
      color: var(--button-text);
    }
    .raw-mode-note {
      font-size: var(--font-size-sm);
      color: var(--text-muted);
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      padding: var(--space-3);
    }
    .defaults {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr)) auto;
      align-items: stretch;
      gap: var(--space-3);
      font-size: var(--font-size-sm);
      padding: var(--space-3);
    }
    .defaults > div {
      display: grid;
      gap: 0.3rem;
      min-width: 0;
    }
    .defaults strong {
      overflow: hidden;
      color: var(--text-primary);
      font-family: var(--monospace-font);
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .defaults-action {
      align-self: center;
      white-space: nowrap;
    }
    .label {
      color: var(--text-muted);
    }
    .stages h3,
    .graph-inspector h3 {
      margin: 0 0 var(--space-2);
      font-size: var(--font-size-sm);
      font-weight: 600;
      letter-spacing: var(--letter-label);
      text-transform: uppercase;
      color: var(--text-muted);
    }
    .stages ul {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: var(--space-1);
    }
    .stages li {
      margin: 0;
    }
    .stage-pick {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: var(--space-2);
      width: 100%;
      padding: var(--space-2) var(--space-3);
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      background: var(--surface);
      font-size: var(--font-size-sm);
      color: inherit;
      cursor: pointer;
      text-align: left;
    }
    .stage-pick:hover {
      border-color: var(--accent);
    }
    .stage-pick.selected {
      border-color: var(--accent);
      box-shadow: 0 0 0 1px var(--accent);
    }
    .stage-id {
      font-family: var(--monospace-font);
      font-weight: 600;
    }
    .stage-type {
      color: var(--accent-active);
      text-transform: uppercase;
      font-size: var(--font-size-xs);
    }
    .stage-deps {
      color: var(--text-muted);
    }
    .graph-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: var(--space-3);
    }
    .graph-layout {
      display: grid;
      grid-template-columns: minmax(0, 1.6fr) minmax(0, 1fr);
      gap: var(--space-4);
      align-items: start;
      min-width: 0;
      max-width: 100%;
    }
    .stage-details {
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
      min-width: 0;
      max-width: 100%;
      position: sticky;
      top: var(--space-3);
    }
    .stage-details-title {
      display: flex;
      justify-content: space-between;
      gap: var(--space-2);
      align-items: baseline;
      color: var(--text-muted);
      font-size: var(--font-size-xs);
      font-weight: 600;
      letter-spacing: var(--letter-label);
      text-transform: uppercase;
    }
    .stage-details-title .muted {
      font-size: 0.7rem;
      font-weight: 400;
      letter-spacing: 0;
      text-transform: none;
    }
    @media (max-width: 1080px) {
      .graph-layout {
        grid-template-columns: 1fr;
      }
      .stage-details {
        position: static;
      }
    }
    @media (max-width: 991px) {
      .defaults { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .defaults-action { justify-self: start; }
      .title-bar {
        flex-direction: column;
        align-items: stretch;
      }
      .primary-actions .btn-primary {
        width: 100%;
      }
    }
    @media (max-width: 560px) {
      .defaults { grid-template-columns: 1fr; }
    }
    .raw {
      max-height: 24rem;
      max-width: 100%;
      overflow: auto;
      box-sizing: border-box;
      background: var(--code-bg, var(--surface));
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      padding: var(--space-3);
      font-family: var(--monospace-font);
      font-size: var(--font-size-sm);
      white-space: pre;
      margin-bottom: var(--space-3);
    }
    .muted {
      color: var(--text-muted);
    }
  `,
})
export class WorkflowDetailComponent implements OnInit {
  readonly facade = inject(WorkflowsFacade);
  readonly capabilities = inject(CapabilitiesService);
  private readonly confirmationDialog = inject(ConfirmationDialogService);
  private readonly destroyRef = inject(DestroyRef);
  private readonly router = inject(Router);
  private readonly selectedStage = inject(SelectedStageStore);

  readonly workflow = input.required<WorkflowDetail>();
  readonly showRaw = signal(false);
  readonly startDialog = viewChild(StartWorkflowDialogComponent);

  selectStage(stageId: string): void {
    this.selectedStage.select(this.workflow().id, stageId);
  }

  isStageSelected(stageId: string): boolean {
    return this.selectedStage.workflowId() === this.workflow().id && this.selectedStage.stageId() === stageId;
  }

  model() {
    return this.workflow().model ?? null;
  }

  readonly effectiveScope = computed(() => this.workflow().effectiveScope ?? this.workflow().scope);
  readonly displayScope = computed(() => this.workflow().scope);
  readonly availableLayers = computed(() => this.workflow().availableScopes ?? [{ scope: this.workflow().scope, overview: '' }]);
  readonly hiddenGlobalLayer = computed(() => {
    const layers = this.availableLayers();
    const effective = this.effectiveScope();
    return effective === 'project' && layers.some((entry) => entry.scope === 'global');
  });
  readonly canDeleteOverride = computed(() => {
    const scope = this.workflow().scope;
    return (scope === 'project' || scope === 'global') && this.capabilities.capabilities().workflowWrites;
  });

  scopeLabel(scope: WorkflowScope): string {
    return SCOPE_LABEL[scope];
  }

  editQueryParams(): Record<string, string> {
    const scope = this.workflow().scope;
    if (scope === 'project' || scope === 'global') {
      return { scope };
    }
    return {};
  }

  async openScope(scope: WorkflowScope): Promise<void> {
    await this.facade.openDetail(this.workflow().id, scope);
  }

  async customize(targetScope: WritableWorkflowScope): Promise<void> {
    const copy = await this.facade.customize(this.workflow().id, { targetScope, sourceScope: 'bundled' });
    if (copy) {
      await this.router.navigate(['/workflows', this.workflow().id, 'edit'], { queryParams: { scope: copy.scope } });
    }
  }

  async deleteOverride(): Promise<void> {
    const scope = this.workflow().scope;
    if (scope !== 'project' && scope !== 'global') {
      return;
    }
    const label = scope === 'project' ? 'project' : 'global';
    const confirmed = await this.confirmationDialog.confirm({
      header: `Delete ${label} override?`,
      message: `The effective definition for "${this.workflow().id}" will fall back to the next layer.`,
      confirmText: 'Delete',
    });
    if (!confirmed) {
      return;
    }
    const ok = await this.facade.remove(this.workflow().id, scope, true);
    if (ok) {
      void this.router.navigate(['/workflows', this.workflow().id]);
    }
  }

  ngOnInit(): void {
    // An overview with an empty inspector forces users through a needless
    // first click. Prefer the first root/actionable stage, then graph order.
    const workflow = this.workflow();
    const graph = workflow.displayGraph;
    const firstStage =
      graph?.nodes.find((node) => node.authored && node.derivedFrom === 'stage')?.id ??
      graph?.nodes[0]?.id ??
      workflow.model?.stages[0]?.id;
    if (firstStage) {
      this.selectedStage.select(workflow.id, firstStage);
    }
    this.destroyRef.onDestroy(() => this.facade.stopRunsPolling());
  }
}
