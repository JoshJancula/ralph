import { Component, ElementRef, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { firstValueFrom } from 'rxjs';
import { ApiService, PlanInventoryItem } from '../services/api.service';
import { WorkflowsFacade } from './workflows.facade';
import { WorkflowsApi } from './workflows-api.service';
import { CapabilitiesService } from './capabilities.service';
import { TasksSchedulesService } from '../services/tasks-schedules.service';
import { ErrorDialogService } from '../services/error-dialog.service';
import { ModelSelectComponent } from './components/model-select.component';
import { WorkflowStageEditorComponent } from './components/workflow-stage-editor.component';
import { isValidStageId } from './pipeline.helpers';
import {
  BLANK_TEMPLATE_ID,
  applyHumanGatePreference,
  buildStageMap,
  buildTemplateCards,
  canAdvanceFromStep1,
  canAdvanceFromStep2,
  canCreate,
  cloneStages,
  collectDraftWarnings,
  createEmptyDraft,
  draftRequiresSuppliedPlan,
  findTemplateCard,
  buildPatternGroups,
  isDraftDirty,
  suggestIdFromTemplate,
  type WizardDraft,
  type WizardStep,
  type WizardTemplateCard,
} from './workflow-new-wizard.helpers';
import type {
  PlanInputModel,
  VerificationProfileModel,
  WorkflowMode,
  WorkflowStageModel,
} from './workflow.types';

const RUNTIME_OPTIONS = ['cursor', 'claude', 'codex', 'opencode', 'antigravity'] as const;

/**
 * Guided New workflow wizard: template outcome cards -> requirements ->
 * stage-map review -> structured editor. Draft stays local until Create.
 */
@Component({
  selector: 'ralph-workflow-new-page',
  standalone: true,
  imports: [FormsModule, ModelSelectComponent, WorkflowStageEditorComponent],
  template: `
    <div class="page" data-testid="workflow-builder">
      <div class="head">
        <h1>New workflow</h1>
        @if (capabilities.capabilities().workflowWrites) {
          <nav class="steps" data-testid="wizard-steps" aria-label="Wizard steps">
            @for (label of stepLabels; track label; let i = $index) {
              <span
                class="step"
                [class.active]="step() === i + 1"
                [class.done]="step() > i + 1"
                [attr.data-testid]="'wizard-step-' + (i + 1)"
                [attr.data-active]="step() === i + 1 ? 'true' : 'false'"
              >
                {{ i + 1 }}. {{ label }}
              </span>
            }
          </nav>
        }
      </div>

      @if (!capabilities.capabilities().workflowWrites) {
        <p class="notice" data-testid="builder-writes-disabled">
          The server is not bound to a loopback host, so workflow writes are disabled.
        </p>
      } @else if (confirmDiscard()) {
        <div class="notice notice-warn" data-testid="wizard-discard-confirm">
          <p>Discard this draft? Nothing has been written to disk yet.</p>
          <div class="actions">
            <button type="button" class="btn btn-ghost" data-testid="wizard-discard-keep" (click)="confirmDiscard.set(false)">
              Keep editing
            </button>
            <button type="button" class="btn btn-danger" data-testid="wizard-discard-confirm-btn" (click)="confirmDiscardDraft()">
              Discard draft
            </button>
          </div>
        </div>
      } @else {
        @switch (step()) {
          @case (1) {
            <section class="panel hub-panel-card" data-testid="wizard-panel-template">
              <p class="lede">What outcome do you want? Pick a pattern, or use Blank for a fully custom pipeline.</p>
              <label class="field">
                <span>Intent (optional)</span>
                <textarea
                  class="control"
                  rows="2"
                  data-testid="wizard-intent"
                  [ngModel]="draft().intent"
                  (ngModelChange)="patchDraft({ intent: $event })"
                  placeholder="Describe what this workflow should accomplish…"
                ></textarea>
              </label>

              @for (group of patternGroups(); track group.outcome) {
                <div class="outcome-group" [attr.data-testid]="'wizard-outcome-' + slug(group.outcome)">
                  <h3 class="outcome-title">{{ group.outcome }}</h3>
                  <div class="card-grid">
                    @for (card of group.cards; track card.id) {
                      <button
                        type="button"
                        class="template-card hub-choice-card"
                        [class.selected]="draft().templateId === card.id"
                        [class.advanced]="card.isAdvanced"
                        [class.is-busy]="activatingPatternId() === card.id || (loadingTemplate() && draft().templateId === card.id)"
                        [disabled]="activatingPatternId() !== null || loadingTemplate()"
                        [attr.data-testid]="card.isBlank ? 'wizard-template-blank' : 'wizard-template-' + card.id"
                        [attr.data-template-id]="card.id"
                        [attr.data-requires-plan]="card.requiresSuppliedPlan ? 'true' : 'false'"
                        [attr.data-has-human-gates]="card.hasHumanGates ? 'true' : 'false'"
                        [attr.data-installable-starter]="card.isInstallableStarter ? 'true' : 'false'"
                        (click)="onPatternChosen(card)"
                      >
                        <span class="card-title">{{ card.title }}</span>
                        <span class="card-purpose">{{ card.purpose }}</span>
                        <span class="card-meta">
                          @if (activatingPatternId() === card.id) {
                            <span class="meta-badge">Installing…</span>
                          } @else if (loadingTemplate() && draft().templateId === card.id) {
                            <span class="meta-badge">Loading…</span>
                          } @else if (card.isBlank) {
                            <span class="meta-badge">Advanced</span>
                          } @else {
                            @if (card.isInstallableStarter) {
                              <span class="meta-badge">Install &amp; customize</span>
                            }
                            @if (card.mode) {
                              <span class="meta-badge">{{ card.mode }}</span>
                            }
                            <span class="meta-badge">{{ card.stageCount }} stages</span>
                            @if (card.requiresSuppliedPlan) {
                              <span class="meta-badge">Requires supplied plan</span>
                            }
                            @if (card.hasHumanGates) {
                              <span class="meta-badge">Human gates</span>
                            }
                          }
                        </span>
                      </button>
                    }
                  </div>
                </div>
              }
            </section>
          }
          @case (2) {
            <section class="panel hub-panel-card" data-testid="wizard-panel-requirements">
              <p class="lede" data-testid="wizard-requirements-lede">
                @if (selectedCard()?.isBlank) {
                  Configure identity and defaults for a blank pipeline.
                } @else if (requiresSuppliedPlan()) {
                  This pattern needs a supplied plan source before Create is ready.
                } @else {
                  Configure identity, task context, and runtime defaults for {{ selectedCard()?.title }}.
                }
              </p>

              <label class="field">
                <span>Id</span>
                <input
                  class="control"
                  type="text"
                  data-testid="builder-id"
                  [ngModel]="draft().id"
                  (ngModelChange)="patchDraft({ id: $event })"
                  required
                />
              </label>
              @if (draft().id && !isValidStageId(draft().id)) {
                <p class="error" data-testid="builder-id-error">Id must be lowercase kebab-case (e.g. my-workflow).</p>
              }

              <label class="field">
                <span>Scope</span>
                <select
                  class="control"
                  data-testid="builder-scope"
                  [ngModel]="draft().scope"
                  (ngModelChange)="patchDraft({ scope: $event })"
                >
                  <option value="project">Project</option>
                  <option value="global">Global</option>
                </select>
              </label>

              <label class="field">
                <span>Name</span>
                <input
                  class="control"
                  type="text"
                  data-testid="builder-name"
                  [ngModel]="draft().name"
                  (ngModelChange)="patchDraft({ name: $event })"
                />
              </label>

              <label class="field">
                <span>Overview</span>
                <textarea
                  class="control"
                  rows="2"
                  data-testid="builder-overview"
                  [ngModel]="draft().overview"
                  (ngModelChange)="patchDraft({ overview: $event })"
                ></textarea>
              </label>

              @if (requiresSuppliedPlan()) {
                <label class="field">
                  <span>Supplied plan source</span>
                  <select
                    class="control"
                    data-testid="wizard-plan-source"
                    [ngModel]="draft().selectedPlanPath ?? ''"
                    (ngModelChange)="onPlanSourceChange($event)"
                  >
                    <option value="">Select a plan…</option>
                    @for (plan of planOptions(); track plan.path) {
                      <option [value]="plan.path">{{ plan.name || plan.id }} ({{ plan.path }})</option>
                    }
                  </select>
                </label>
                @if (!draft().selectedPlanPath) {
                  <p class="error" data-testid="wizard-plan-required">
                    A valid supplied plan source is required before Create can claim readiness.
                  </p>
                }
              } @else if (!selectedCard()?.isBlank) {
                <label class="field">
                  <span>Task description</span>
                  <textarea
                    class="control"
                    rows="3"
                    data-testid="wizard-task"
                    [ngModel]="draft().taskDescription"
                    (ngModelChange)="patchDraft({ taskDescription: $event })"
                    placeholder="What should a run of this workflow accomplish?"
                  ></textarea>
                </label>
              }

              <div class="row">
                <label class="field">
                  <span>Default runtime</span>
                  <select
                    class="control"
                    data-testid="builder-defaults-runtime"
                    [ngModel]="draft().defaultsRuntime"
                    (ngModelChange)="onDefaultsRuntimeChange($event)"
                  >
                    <option value="">inherit</option>
                    @for (rt of runtimeOptions; track rt) {
                      <option [value]="rt">{{ rt }}</option>
                    }
                  </select>
                </label>
                @if (draft().defaultsRuntime) {
                  <ralph-model-select
                    data-testid="builder-defaults-model"
                    [runtime]="draft().defaultsRuntime"
                    [model]="draft().defaultsModel"
                    (modelChange)="patchDraft({ defaultsModel: $event })"
                  />
                } @else {
                  <label class="field">
                    <span>Default model</span>
                    <select class="control" data-testid="builder-defaults-model-inherit" disabled>
                      <option value="">inherit</option>
                    </select>
                  </label>
                }
              </div>

              @if (selectedCard()?.hasHumanGates || selectedCard()?.isBlank) {
                <label class="check-field" data-testid="wizard-human-gates-field">
                  <input
                    type="checkbox"
                    data-testid="wizard-prefer-human-gates"
                    [ngModel]="draft().preferHumanGates"
                    (ngModelChange)="onPreferHumanGatesChange($event)"
                  />
                  <span>Keep human approval / input gates</span>
                </label>
              }

              @if (selectedCard()?.isBlank) {
                <label class="field">
                  <span>Mode</span>
                  <select
                    class="control"
                    data-testid="builder-mode"
                    [ngModel]="draft().mode"
                    (ngModelChange)="patchDraft({ mode: $event })"
                  >
                    <option value="dependency">Dependency</option>
                    <option value="sequential">Sequential</option>
                  </select>
                </label>
              }
            </section>
          }
          @case (3) {
            <section class="panel hub-panel-card" data-testid="wizard-panel-stage-map">
              <p class="lede">Review the resolved stage map before customizing. Nothing is written yet.</p>
              <dl class="summary" data-testid="wizard-stage-map-summary">
                <div>
                  <dt>Template</dt>
                  <dd data-testid="wizard-review-template">{{ selectedCard()?.title || '—' }}</dd>
                </div>
                <div>
                  <dt>Mode</dt>
                  <dd data-testid="wizard-review-mode">{{ draft().mode }}</dd>
                </div>
                <div>
                  <dt>Stages</dt>
                  <dd data-testid="wizard-review-stage-count">{{ draft().stages.length }}</dd>
                </div>
                @if (draft().selectedPlanPath) {
                  <div>
                    <dt>Plan source</dt>
                    <dd data-testid="wizard-review-plan">{{ draft().selectedPlanName || draft().selectedPlanPath }}</dd>
                  </div>
                }
              </dl>

              <ol class="stage-map" data-testid="wizard-stage-map">
                @for (entry of stageMap(); track entry.id) {
                  <li
                    class="stage-map-item hub-nested-panel"
                    data-testid="wizard-stage-map-item"
                    [attr.data-stage-id]="entry.id"
                    [attr.data-stage-kind]="entry.kind"
                  >
                    <span class="stage-id">{{ entry.id }}</span>
                    <span class="stage-kind">{{ entry.type || entry.kind }}</span>
                    @if (entry.dependsOn.length > 0) {
                      <span class="stage-deps">depends on {{ entry.dependsOn.join(', ') }}</span>
                    }
                  </li>
                } @empty {
                  <li class="muted" data-testid="wizard-stage-map-empty">No stages yet.</li>
                }
              </ol>

              @if (draft().warnings.length > 0) {
                <ul class="warnings" data-testid="wizard-warnings">
                  @for (warning of draft().warnings; track warning) {
                    <li data-testid="wizard-warning">{{ warning }}</li>
                  }
                </ul>
              }
            </section>
          }
          @case (4) {
            <section class="panel hub-panel-card" data-testid="wizard-panel-editor">
              <p class="lede">Customize stages, then create. Filesystem write happens only on Create.</p>

              <label class="field">
                <span>Mode</span>
                <select
                  class="control"
                  data-testid="builder-mode"
                  [ngModel]="draft().mode"
                  (ngModelChange)="patchDraft({ mode: $event })"
                >
                  <option value="dependency">Dependency</option>
                  <option value="sequential">Sequential</option>
                </select>
              </label>

              <div class="row">
                <label class="field">
                  <span>Max parallel</span>
                  <input
                    class="control"
                    type="number"
                    min="1"
                    data-testid="builder-max-parallel"
                    [ngModel]="draft().maxParallel"
                    (ngModelChange)="patchDraft({ maxParallel: +$event })"
                  />
                </label>
                <label class="field">
                  <span>Max rework iterations</span>
                  <input
                    class="control"
                    type="number"
                    min="1"
                    max="5"
                    data-testid="builder-max-rework"
                    [ngModel]="draft().maxReworkIterations"
                    (ngModelChange)="patchDraft({ maxReworkIterations: +$event })"
                  />
                </label>
              </div>
              @if (draft().maxReworkIterations < 1 || draft().maxReworkIterations > 5) {
                <p class="error" data-testid="builder-max-rework-error">Max rework iterations must be between 1 and 5.</p>
              }

              @if (requiresSuppliedPlan() && !draft().selectedPlanPath) {
                <p class="error" data-testid="wizard-plan-required">
                  A valid supplied plan source is required before Create can claim readiness.
                </p>
              }

              <ralph-workflow-stage-editor [stagesValue]="draft().stages" [verificationProfiles]="draft().verificationProfiles" (stagesChange)="onStagesChange($event)" />

              @if (facade.error(); as message) {
                <p class="error" data-testid="builder-error">{{ message }}</p>
              }
            </section>
          }
        }

        <div class="actions wizard-actions" data-testid="wizard-actions">
          <button type="button" class="btn btn-ghost" data-testid="wizard-cancel" (click)="onCancel()">Cancel</button>
          @if (step() > 1) {
            <button type="button" class="btn btn-secondary" data-testid="wizard-back" (click)="goBack()">Back</button>
          }
          @if (step() < 4) {
            <button
              type="button"
              class="btn btn-primary"
              data-testid="wizard-next"
              [disabled]="!canGoNext() || loadingTemplate()"
              (click)="goNext()"
            >
              {{ loadingTemplate() ? 'Loading…' : 'Next' }}
            </button>
          } @else {
            <button
              type="button"
              class="btn btn-primary"
              data-testid="builder-create"
              [disabled]="facade.saving() || !canSubmit()"
              (click)="submit()"
            >
              {{ facade.saving() ? 'Creating…' : 'Create workflow' }}
            </button>
          }
        </div>
      }
    </div>
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      min-height: 0;
    }
    .page {
      display: flex;
      flex-direction: column;
      gap: 1rem;
      max-width: 52rem;
      width: 100%;
      flex: 1;
      min-height: 0;
      overflow-x: hidden;
      overflow-y: auto;
      padding-bottom: 2rem;
    }
    .head {
      display: flex;
      flex-direction: column;
      gap: 0.6rem;
    }
    h1 {
      margin: 0;
      color: var(--text-primary);
    }
    .steps {
      display: flex;
      flex-wrap: wrap;
      gap: 0.4rem 0.75rem;
      font-size: 0.78rem;
      color: var(--text-muted);
    }
    .step.active {
      color: var(--text-primary);
      font-weight: 600;
    }
    .step.done {
      color: var(--text-muted);
    }
    .panel {
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
    }
    .lede {
      margin: 0;
      color: var(--text-muted);
      font-size: 0.9rem;
    }
    .outcome-group {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }
    .outcome-title {
      margin: 0;
      font-size: 0.85rem;
      color: var(--text-primary);
    }
    .card-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(14rem, 1fr));
      gap: 0.6rem;
    }
    .template-card.advanced {
      border-style: dashed;
    }
    .template-card.is-busy {
      opacity: 0.85;
    }
    .card-title {
      font-weight: 600;
      font-size: 0.88rem;
    }
    .card-purpose {
      font-size: 0.78rem;
      color: var(--text-muted);
      line-height: 1.35;
    }
    .card-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 0.25rem;
    }
    .meta-badge {
      font-size: 0.68rem;
      padding: 0.1rem 0.35rem;
      border-radius: 4px;
      border: 1px solid var(--border);
      color: var(--text-muted);
    }
    .field {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
      font-size: 0.82rem;
      color: var(--text-muted);
    }
    .check-field {
      display: flex;
      align-items: center;
      gap: 0.45rem;
      font-size: 0.85rem;
      color: var(--text-primary);
    }
    .row {
      display: flex;
      gap: 0.75rem;
    }
    .row .field {
      flex: 1;
    }
    .error {
      color: var(--danger);
      font-size: 0.8rem;
      margin: 0;
    }
    .notice {
      color: var(--text-muted);
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 0.6rem 0.75rem;
    }
    .notice-warn {
      border-color: var(--warning, #b45309);
      color: var(--text-primary);
    }
    .summary {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(10rem, 1fr));
      gap: 0.5rem 1rem;
      margin: 0;
    }
    .summary dt {
      font-size: 0.72rem;
      color: var(--text-muted);
    }
    .summary dd {
      margin: 0.1rem 0 0;
      font-size: 0.88rem;
      color: var(--text-primary);
    }
    .stage-map {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: 0.4rem;
    }
    .stage-map-item {
      display: flex;
      flex-wrap: wrap;
      gap: 0.4rem 0.75rem;
      align-items: baseline;
      font-size: 0.82rem;
    }
    .stage-id {
      font-weight: 600;
      font-family: var(--monospace-font, ui-monospace, monospace);
    }
    .stage-kind {
      color: var(--text-muted);
    }
    .stage-deps {
      color: var(--text-muted);
      font-size: 0.75rem;
    }
    .warnings {
      margin: 0;
      padding-left: 1.1rem;
      color: var(--warning, #b45309);
      font-size: 0.8rem;
    }
    .muted {
      color: var(--text-muted);
      font-size: 0.85rem;
    }
    .actions {
      display: flex;
      justify-content: flex-end;
      gap: 0.5rem;
      flex-wrap: wrap;
    }
    .wizard-actions {
      position: sticky;
      bottom: 0;
      padding-top: 0.5rem;
      background: linear-gradient(transparent, var(--background, var(--surface)) 30%);
    }
    .btn-danger {
      background: var(--danger, #b91c1c);
      color: var(--text-on-danger, #fff);
      border-color: transparent;
    }
  `,
})
export class WorkflowNewPageComponent implements OnInit {
  readonly facade = inject(WorkflowsFacade);
  readonly capabilities = inject(CapabilitiesService);
  private readonly taskSchedules = inject(TasksSchedulesService);
  private readonly api = inject(WorkflowsApi);
  private readonly plansApi = inject(ApiService);
  private readonly router = inject(Router);
  private readonly errorDialog = inject(ErrorDialogService);
  private readonly host = inject(ElementRef<HTMLElement>);

  readonly isValidStageId = isValidStageId;
  readonly runtimeOptions = RUNTIME_OPTIONS;
  readonly stepLabels = ['Pattern', 'Requirements', 'Stage map', 'Customize'] as const;

  readonly draft = signal<WizardDraft>(createEmptyDraft());
  readonly planOptions = signal<readonly PlanInventoryItem[]>([]);
  readonly loadingTemplate = signal(false);
  readonly confirmDiscard = signal(false);
  readonly starters = signal<
    Array<{ id: string; category: string; purpose: string; outputs: string; safety: string; installable: boolean; stageCount: number }>
  >([]);
  readonly activatingPatternId = signal<string | null>(null);

  /** Cached stages from the last loaded template before human-gate stripping. */
  private templateStages: WorkflowStageModel[] = [];

  readonly step = computed(() => this.draft().step);
  readonly templateCards = computed(() => buildTemplateCards(this.facade.workflows()));
  readonly patternGroups = computed(() => buildPatternGroups(this.templateCards(), this.starters()));
  readonly selectedCard = computed(() => findTemplateCard(this.templateCards(), this.draft().templateId));
  readonly requiresSuppliedPlan = computed(() => draftRequiresSuppliedPlan(this.draft(), this.templateCards()));
  readonly stageMap = computed(() => buildStageMap(this.draft().stages));

  ngOnInit(): void {
    void this.facade.load();
    this.capabilities.load();
    this.taskSchedules.templates().subscribe({
      next: (starters) => this.starters.set(starters.filter((starter) => starter.installable)),
    });
    void this.loadPlans();
  }

  slug(value: string): string {
    return value
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, '');
  }

  patchDraft(partial: Partial<WizardDraft>): void {
    this.draft.update((current) => {
      const next = { ...current, ...partial };
      return { ...next, warnings: this.refreshWarnings(next) };
    });
    this.facade.markBuilderDirty(isDraftDirty(this.draft()));
  }

  selectTemplate(card: WizardTemplateCard): void {
    this.patchDraft({
      templateId: card.id,
      preferHumanGates: card.hasHumanGates || card.isBlank ? true : this.draft().preferHumanGates,
    });
  }

  async onPatternChosen(card: WizardTemplateCard): Promise<void> {
    if (this.activatingPatternId() || this.loadingTemplate()) {
      return;
    }
    try {
      if (card.isInstallableStarter) {
        this.activatingPatternId.set(card.id);
        await firstValueFrom(this.taskSchedules.installTemplate(card.id));
        await this.facade.load();
      }
      const resolved = findTemplateCard(this.templateCards(), card.id) ?? card;
      this.selectTemplate(resolved);
      if (this.draft().step !== 1 || !this.canGoNext()) {
        return;
      }
      await this.goNext();
      this.scrollWizardIntoView();
    } catch (err: unknown) {
      void this.errorDialog.displayError(err, `Could not use pattern "${card.id}".`);
    } finally {
      this.activatingPatternId.set(null);
    }
  }

  private scrollWizardIntoView(): void {
    queueMicrotask(() => {
      this.host.nativeElement.querySelector('.head')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
  }

  canGoNext(): boolean {
    const d = this.draft();
    if (d.step === 1) {
      return canAdvanceFromStep1(d);
    }
    if (d.step === 2) {
      return canAdvanceFromStep2(d, this.requiresSuppliedPlan());
    }
    return d.step === 3;
  }

  canSubmit(): boolean {
    return canCreate(this.draft(), this.requiresSuppliedPlan());
  }

  async goNext(): Promise<void> {
    if (!this.canGoNext()) {
      return;
    }
    const d = this.draft();
    if (d.step === 1) {
      await this.seedFromTemplate(d.templateId!);
      this.patchDraft({ step: 2 });
      return;
    }
    if (d.step === 2) {
      this.patchDraft({
        step: 3,
        warnings: this.refreshWarnings(this.draft()),
      });
      return;
    }
    if (d.step === 3) {
      this.patchDraft({ step: 4 });
    }
  }

  goBack(): void {
    const step = this.draft().step;
    if (step <= 1) {
      return;
    }
    this.patchDraft({ step: (step - 1) as WizardStep });
  }

  onCancel(): void {
    if (isDraftDirty(this.draft())) {
      this.confirmDiscard.set(true);
      return;
    }
    void this.router.navigate(['/workflows']);
  }

  confirmDiscardDraft(): void {
    this.draft.set(createEmptyDraft());
    this.templateStages = [];
    this.facade.markBuilderDirty(false);
    this.confirmDiscard.set(false);
    void this.router.navigate(['/workflows']);
  }

  onPlanSourceChange(path: string): void {
    const plan = this.planOptions().find((p) => p.path === path);
    this.patchDraft({
      selectedPlanPath: path || null,
      selectedPlanName: plan ? plan.name || plan.id : null,
    });
  }

  onDefaultsRuntimeChange(runtime: string): void {
    const current = this.draft();
    this.patchDraft({
      defaultsRuntime: runtime,
      defaultsModel: runtime === current.defaultsRuntime ? current.defaultsModel : '',
    });
  }

  onPreferHumanGatesChange(prefer: boolean): void {
    const stages = applyHumanGatePreference(this.templateStages, prefer);
    this.patchDraft({ preferHumanGates: prefer, stages });
  }

  onStagesChange(stages: WorkflowStageModel[]): void {
    this.patchDraft({ stages });
  }

  async submit(): Promise<void> {
    if (!this.canSubmit()) {
      return;
    }
    const d = this.draft();
    const ok = await this.facade.create({
      id: d.id,
      scope: d.scope,
      name: d.name || undefined,
      overview: d.overview || undefined,
      mode: d.mode,
      defaults:
        d.defaultsRuntime || d.defaultsModel
          ? { runtime: d.defaultsRuntime || undefined, model: d.defaultsModel || undefined }
          : undefined,
      planInput: d.planInput,
      pipeline: {
        maxParallel: d.maxParallel,
        maxReworkIterations: d.maxReworkIterations,
        publishMode: d.publishMode,
        verificationProfiles: d.verificationProfiles,
        stages: d.stages,
      },
    });
    if (ok) {
      void this.router.navigate(['/workflows', d.id]);
    }
  }

  private refreshWarnings(draft: WizardDraft): string[] {
    return collectDraftWarnings({
      draft,
      requiresPlan: draftRequiresSuppliedPlan(draft, this.templateCards()),
      templateHasHumanGates: findTemplateCard(this.templateCards(), draft.templateId)?.hasHumanGates === true,
    });
  }

  private async loadPlans(): Promise<void> {
    try {
      const response = await firstValueFrom(this.plansApi.fetchPlanIndex({ type: 'leaf', pageSize: 100 }));
      this.planOptions.set(response.items ?? []);
    } catch {
      this.planOptions.set([]);
    }
  }

  private async seedFromTemplate(templateId: string): Promise<void> {
    if (templateId === BLANK_TEMPLATE_ID) {
      this.templateStages = [];
      const intent = this.draft().intent.trim();
      this.patchDraft({
        templateId: BLANK_TEMPLATE_ID,
        id: this.draft().id || suggestIdFromTemplate(null),
        name: this.draft().name || intent || '',
        overview: this.draft().overview || intent || '',
        mode: this.draft().mode || 'dependency',
        stages: [],
        planInput: undefined,
        verificationProfiles: undefined,
        publishMode: undefined,
        unsupportedKeys: [],
        selectedPlanPath: null,
        selectedPlanName: null,
        preferHumanGates: true,
        templateLoadError: null,
      });
      return;
    }

    this.loadingTemplate.set(true);
    try {
      const detail = await firstValueFrom(this.api.getWorkflow(templateId));
      const model = detail.model;
      if (!model) {
        this.templateStages = [];
        this.patchDraft({
          stages: [],
          unsupportedKeys: detail.unsupportedKeys ? [...detail.unsupportedKeys] : ['unstructured'],
          templateLoadError: 'Template has no structured model; continue in the editor or pick another pattern.',
        });
        return;
      }

      const baseStages = cloneStages(model.stages);
      this.templateStages = baseStages;
      const preferGates = this.draft().preferHumanGates;
      const stages = applyHumanGatePreference(baseStages, preferGates);
      const intent = this.draft().intent.trim();
      const planInput: PlanInputModel | undefined = model.planInput
        ? { stage: model.planInput.stage, required: model.planInput.required }
        : undefined;
      const verificationProfiles: VerificationProfileModel[] | undefined = model.verificationProfiles
        ? model.verificationProfiles.map((profile) => ({
            name: profile.name,
            steps: profile.steps.map((step) => ({ ...step })),
          }))
        : undefined;

      this.patchDraft({
        templateId,
        id: this.draft().id || suggestIdFromTemplate(templateId),
        name: this.draft().name || model.name || templateId,
        overview: this.draft().overview || intent || model.overview || '',
        mode: ((model.mode as WorkflowMode) || 'dependency') as WorkflowMode,
        defaultsRuntime: model.defaultsRuntime ?? this.draft().defaultsRuntime,
        defaultsModel: model.defaultsModel ?? this.draft().defaultsModel,
        maxParallel: model.maxParallel ?? this.draft().maxParallel,
        maxReworkIterations: model.maxReworkIterations ?? this.draft().maxReworkIterations,
        stages,
        planInput,
        publishMode: model.publishMode,
        verificationProfiles,
        unsupportedKeys: [...(model.unsupportedKeys ?? [])],
        templateLoadError: null,
      });
    } catch {
      this.templateStages = [];
      this.patchDraft({
        templateLoadError: `Could not load template "${templateId}". Draft stages were not changed.`,
      });
    } finally {
      this.loadingTemplate.set(false);
    }
  }
}
