import { Component, effect, input, output, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import {
  addStage,
  findDanglingDependency,
  findInvalidStageId,
  findStageCycle,
  isValidStageId,
  moveStage,
  removeStage,
} from '../pipeline.helpers';
import { ModelSelectComponent } from './model-select.component';
import type { OrdinaryStageModel, PathEntry, SupervisorStageModel, VerificationProfileModel, WorkflowStageModel } from '../workflow.types';

const RUNTIME_OPTIONS = ['cursor', 'claude', 'codex', 'opencode', 'antigravity'] as const;

/**
 * Ported from trade-beacon's workflow-pipeline-editor.component.ts with
 * Ralph stage fields (id, dependsOn, runtime, model, instructions, produces,
 * requires) replacing trade-beacon's type/outputFileName/isFinalOutput.
 * Supervisor-typed stages render read-only, matching docs/WORKFLOWS.md
 * "Supervisor nodes ... accept no runtime, model, instructions, TODOs, or
 * mutation scopes." See port-design.md "Component decisions".
 */
@Component({
  selector: 'ralph-workflow-stage-editor',
  standalone: true,
  imports: [FormsModule, ModelSelectComponent],
  template: `
    <div class="editor" data-testid="pipeline-editor">
      <div class="toolbar">
        <button type="button" class="btn btn-secondary" data-testid="pipeline-add-stage" (click)="onAddStage()">
          Add stage
        </button>
      </div>

      @if (cycleError(); as message) {
        <p class="notice notice-warn" data-testid="pipeline-cycle-error">{{ message }}</p>
      }
      @if (invalidIdError(); as message) {
        <p class="notice notice-warn" data-testid="pipeline-invalid-id-error">{{ message }}</p>
      }
      @if (danglingError(); as message) {
        <p class="notice notice-warn" data-testid="pipeline-dangling-error">{{ message }}</p>
      }

      @for (stage of stages(); track stage.id; let i = $index) {
        <details class="stage-card hub-panel-card" [open]="expanded().has(stage.id)" data-testid="pipeline-stage">
          <summary class="stage-summary" (click)="toggleExpanded(stage.id, $event)">
            <span class="index">{{ i + 1 }}</span>
            <span class="stage-id">{{ stage.id }}</span>
            @if (stage.kind === 'supervisor') {
              <span class="badge">{{ stage.type }}</span>
            }
            <span class="hint">{{ expanded().has(stage.id) ? 'Close' : 'Edit stage' }}</span>
          </summary>

          <div class="stage-body">
            <label class="field">
              <span>Id</span>
              <input
                class="control"
                type="text"
                [value]="stage.id"
                [disabled]="stage.kind === 'supervisor'"
                (input)="onIdChange(stage.id, $event)"
              />
            </label>

            @if (stage.kind === 'ordinary') {
              <label class="field">
                <span>Instructions</span>
                <textarea class="control" rows="10" [value]="stage.instructions ?? ''" (input)="onInstructionsChange(stage.id, $event)"></textarea>
                <span class="help">Stage guidance injected as WORKFLOW_STAGE_INSTRUCTIONS. Use INCLUDE tokens for shared fragments.</span>
              </label>

              <label class="field">
                <span>Runtime override</span>
                <select class="control" [ngModel]="stage.runtime ?? ''" [ngModelOptions]="{ standalone: true }" (ngModelChange)="onRuntimeChange(stage.id, $event)">
                  <option value="">inherit</option>
                  @for (runtime of runtimeOptions; track runtime) {
                    <option [value]="runtime">{{ runtime }}</option>
                  }
                </select>
              </label>

              @if (stage.runtime) {
                <ralph-model-select [runtime]="stage.runtime" [model]="stage.model ?? ''" (modelChange)="onModelChange(stage.id, $event)" />
              }

              <label class="field">
                <span>Session strategy</span>
                <select class="control" data-testid="stage-session-strategy-select" [value]="stage.sessionStrategy ?? ''" (change)="onSessionStrategyChange(stage.id, $any($event.target).value)">
                  <option value="">inherit (fresh by default)</option>
                  <option value="fresh">fresh — isolate each TODO</option>
                  <option value="resume">resume — retain full context</option>
                  <option value="reset">reset — retain ID, reset context</option>
                  <option value="compact">compact — retain continuity, compact context</option>
                </select>
                <span class="help">Use resume for short cohesive stages, compact for long implementation plans, and fresh for independent review or QA.</span>
              </label>

              <fieldset class="field" data-testid="stage-planner-fields">
                <legend>Planner / planFrom</legend>
                <span class="help">Planner stages emit a plan-file artifact. Consumers declare planFrom with that stage id.</span>
                <label class="checkbox-row">
                  <input type="checkbox" [checked]="!!stage.planner" (change)="onTogglePlanner(stage.id, $event)" />
                  Planner stage (emits plan checklist for downstream stages)
                </label>
                @if (stage.planner) {
                  <label class="field">
                    <span>maxTodos (maximum checklist tasks)</span>
                    <input class="control" type="number" min="1" max="200" [value]="stage.planner.maxTodos ?? 100" (input)="onPlannerMaxTodos(stage.id, $event)" />
                    <span class="help">Cap on TODO checklist tasks generated by this planner (default: 100, max: 200).</span>
                  </label>
                }
                @if (!stage.planner) {
                  <label class="field">
                    <span>planFrom (planner stage)</span>
                    @if (availablePlannerStages(stage.id).length > 0) {
                      <select
                        class="control"
                        data-testid="stage-plan-from-select"
                        [ngModel]="stage.planFrom ?? ''"
                        [ngModelOptions]="{ standalone: true }"
                        (ngModelChange)="onPlanFromChange(stage.id, $event)"
                      >
                        <option value="">None (self-directed or manual plan)</option>
                        @for (p of availablePlannerStages(stage.id); track p.id) {
                          <option [value]="p.id">{{ p.id }} (stage {{ stageIndex(p.id) + 1 }})</option>
                        }
                        @if (stage.planFrom && !isAvailablePlanner(stage.planFrom, stage.id)) {
                          <option [value]="stage.planFrom">{{ stage.planFrom }} (custom)</option>
                        }
                      </select>
                    } @else {
                      <input
                        class="control"
                        type="text"
                        placeholder="planner-stage-id (or leave empty)"
                        [value]="stage.planFrom ?? ''"
                        (input)="onPlanFromChange(stage.id, $event)"
                      />
                    }
                    <span class="help">Upstream planner stage that produces the task checklist for this stage.</span>
                  </label>
                }
              </fieldset>

              <fieldset class="field" data-testid="stage-mutation-fields">
                <legend>Workspace / write scope / git</legend>
                <span class="help">Mutating stages need an explicit write scope. Write capability is high salience for operators.</span>
                <label class="field">
                  <span>workspaceMode</span>
                  <select class="control" [ngModel]="stage.workspaceMode ?? ''" [ngModelOptions]="{ standalone: true }" (ngModelChange)="onWorkspaceModeChange(stage.id, $event)">
                    <option value="">default (shared)</option>
                    <option value="shared">shared</option>
                    <option value="snapshot">snapshot</option>
                    <option value="worktree">worktree</option>
                  </select>
                </label>
                <label class="field">
                  <span class="write-salience">writeScopes</span>
                  <input class="control" type="text" placeholder='["**"]' [value]="writeScopesText(stage)" (input)="onWriteScopesChange(stage.id, $event)" />
                </label>
                <label class="field">
                  <span>agentGitAccess</span>
                  <select class="control" [ngModel]="stage.agentGitAccess ?? ''" [ngModelOptions]="{ standalone: true }" (ngModelChange)="onGitAccessChange(stage.id, $event)">
                    <option value="">unset</option>
                    <option value="inherit">inherit</option>
                    <option value="off">off</option>
                    <option value="on">on</option>
                  </select>
                </label>
              </fieldset>

              <fieldset class="field" data-testid="stage-loop-fields">
                <legend>Rework loop</legend>
                <span class="help">Configure loopback for review stages. When work is rejected, execution resets to an upstream stage.</span>
                <label class="field">
                  <span>loopBackTo (target stage)</span>
                  <select
                    class="control"
                    data-testid="stage-loopback-to-select"
                    [ngModel]="stage.loopBackTo ?? ''"
                    [ngModelOptions]="{ standalone: true }"
                    (ngModelChange)="onLoopBackToChange(stage.id, $event)"
                  >
                    <option value="">None (no rework loop)</option>
                    @for (prev of previousStages(i); track prev.id) {
                      <option [value]="prev.id">{{ prev.id }} (stage {{ stageIndex(prev.id) + 1 }}: {{ prev.kind === 'supervisor' ? prev.type : 'ordinary' }})</option>
                    }
                    @if (stage.loopBackTo && !isPreviousStage(i, stage.loopBackTo)) {
                      <option [value]="stage.loopBackTo">{{ stage.loopBackTo }} (warning: target must precede this stage)</option>
                    }
                  </select>
                  <span class="help">Upstream stage to rerun when changes or fixes are required. Must precede this stage in workflow order.</span>
                </label>
                @if (stage.loopBackTo) {
                  <label class="field">
                    <span>onExhausted (when rework limit is reached)</span>
                    <select
                      class="control"
                      data-testid="stage-on-exhausted-select"
                      [ngModel]="stage.onExhausted ?? 'fail'"
                      [ngModelOptions]="{ standalone: true }"
                      (ngModelChange)="onOnExhaustedChange(stage.id, $event)"
                    >
                      <option value="fail">fail — Stop workflow run with failure (default)</option>
                      <option value="proceed">proceed — Proceed anyway to subsequent stages</option>
                    </select>
                    <span class="help">Action taken if review defects remain after maximum rework iterations (maxReworkIterations) are exhausted.</span>
                  </label>

                  <div class="row">
                    <label class="field">
                      <span>loopCheck path</span>
                      <input
                        class="control"
                        type="text"
                        placeholder=".ralph-workspace/artifacts/{{'{{'}}ARTIFACT_NS{{'}}'}}/review-verdict.json"
                        [value]="stage.loopCheck?.path ?? ''"
                        (input)="onLoopCheckPathChange(stage.id, $event)"
                      />
                      <span class="help">Path to the verdict JSON file inspected by the rework loop.</span>
                    </label>
                    <label class="field">
                      <span>loopCheck schema (optional)</span>
                      <input
                        class="control"
                        type="text"
                        placeholder="e.g. verdict-schema-v1"
                        [value]="stage.loopCheck?.schema ?? ''"
                        (input)="onLoopCheckSchemaChange(stage.id, $event)"
                      />
                    </label>
                  </div>
                }
              </fieldset>

              <fieldset class="field">
                <legend>Produces</legend>
                @for (entry of stage.produces; track $index; let pi = $index) {
                  <div class="path-row">
                    <input class="control" type="text" placeholder="path" [value]="entry.path" (input)="onPathChange(stage.id, 'produces', pi, $event)" />
                    <input class="control" type="text" placeholder="schema (optional)" [value]="entry.schema ?? ''" (input)="onPathSchemaChange(stage.id, 'produces', pi, $event)" />
                    <label class="checkbox-row">
                      <input type="checkbox" [checked]="entry.required" (change)="onPathRequiredChange(stage.id, 'produces', pi, $event)" />
                      required
                    </label>
                    <button type="button" class="btn btn-danger" (click)="removePath(stage.id, 'produces', pi)">Remove</button>
                  </div>
                }
                <button type="button" class="btn btn-ghost" (click)="addPath(stage.id, 'produces')">Add produces path</button>
              </fieldset>

              <fieldset class="field">
                <legend>Requires</legend>
                @for (entry of stage.requires; track $index; let ri = $index) {
                  <div class="path-row">
                    <input class="control" type="text" placeholder="path" [value]="entry.path" (input)="onPathChange(stage.id, 'requires', ri, $event)" />
                    <input class="control" type="text" placeholder="schema (optional)" [value]="entry.schema ?? ''" (input)="onPathSchemaChange(stage.id, 'requires', ri, $event)" />
                    <label class="checkbox-row">
                      <input type="checkbox" [checked]="entry.required" (change)="onPathRequiredChange(stage.id, 'requires', ri, $event)" />
                      required
                    </label>
                    <button type="button" class="btn btn-danger" (click)="removePath(stage.id, 'requires', ri)">Remove</button>
                  </div>
                }
                <button type="button" class="btn btn-ghost" (click)="addPath(stage.id, 'requires')">Add requires path</button>
              </fieldset>

              @if (stage.router) {
                <fieldset class="field" data-testid="stage-router-fields">
                  <legend>Router</legend>
                  <span class="help">Router targets are authored on ordinary classify stages.</span>
                  <p class="supervisor-note">defaultTarget: {{ stage.router.defaultTarget }}; allowed: {{ stage.router.allowedTargets.join(', ') }}</p>
                </fieldset>
              }
            } @else {
              <p class="supervisor-note" data-testid="supervisor-readonly-note">
                Supervisor stages ({{ stage.type }}) take no runtime, model, instructions, planner, planFrom, or write scopes.
              </p>
              @if (stage.type === 'gate') {
                <label class="field">
                  <span>Gate verification profile</span>
                  @if (availableVerificationProfiles().length > 0) {
                    <select
                      class="control"
                      data-testid="supervisor-gate-profile-select"
                      [ngModel]="stage.profile ?? ''"
                      [ngModelOptions]="{ standalone: true }"
                      (ngModelChange)="onSupervisorProfileChange(stage.id, $event)"
                    >
                      <option value="" disabled>Select a verification profile…</option>
                      @for (prof of availableVerificationProfiles(); track prof) {
                        <option [value]="prof">{{ prof }}</option>
                      }
                      @if (stage.profile && !availableVerificationProfiles().includes(stage.profile)) {
                        <option [value]="stage.profile">{{ stage.profile }} (custom)</option>
                      }
                    </select>
                  } @else {
                    <input
                      class="control"
                      type="text"
                      placeholder="e.g. release-verdict"
                      [value]="stage.profile ?? ''"
                      (input)="onSupervisorProfileChange(stage.id, $event)"
                    />
                  }
                  <span class="help">Must match a profile name in verificationProfiles. The gate stage executes all steps in this profile.</span>
                </label>
              }
              @if (stage.type === 'integrate') {
                <label class="field">
                  <span>workspaceMode</span>
                  <select class="control" [ngModel]="stage.workspaceMode ?? ''" [ngModelOptions]="{ standalone: true }" (ngModelChange)="onSupervisorWorkspaceModeChange(stage.id, $event)">
                    <option value="">unset</option>
                    <option value="snapshot">snapshot</option>
                    <option value="worktree">worktree</option>
                  </select>
                </label>
              }
              @if (stage.type === 'approval') {
                <label class="field">
                  <span>Question for operator</span>
                  <input class="control" type="text" placeholder="e.g. Approve this release for deployment?" [value]="stage.question ?? ''" (input)="onSupervisorQuestionChange(stage.id, $event)" />
                  <span class="help">Prompt presented to the human operator during this approval pause.</span>
                </label>
                <label class="field">
                  <span>Changes target (upstream stage to reset on request-changes)</span>
                  <select
                    class="control"
                    data-testid="supervisor-changes-target-select"
                    [ngModel]="stage.changesTarget ?? ''"
                    [ngModelOptions]="{ standalone: true }"
                    (ngModelChange)="onSupervisorChangesTargetChange(stage.id, $event)"
                  >
                    <option value="">None (stop workflow if changes requested)</option>
                    @for (prev of previousStages(i); track prev.id) {
                      <option [value]="prev.id">{{ prev.id }} (stage {{ stageIndex(prev.id) + 1 }})</option>
                    }
                    @if (stage.changesTarget && !isPreviousStage(i, stage.changesTarget)) {
                      <option [value]="stage.changesTarget">{{ stage.changesTarget }} (custom)</option>
                    }
                  </select>
                  <span class="help">Upstream stage to reset and rerun if the operator chooses 'request-changes'.</span>
                </label>
              }
              @if (stage.type === 'consensus' && stage.voters) {
                <p class="supervisor-note" data-testid="consensus-voters-note">
                  Consensus voters ({{ stage.voters.length }}): {{ stage.voters.map(v => v.id).join(', ') }}. Policy={{ stage.policy ?? '—' }}, quorum={{ stage.quorum ?? '—' }}.
                </p>
              }
              @if (stage.requires?.length) {
                <p class="supervisor-note">Requires {{ stage.requires!.length }} artifact(s).</p>
              }
            }

            <fieldset class="field">
              <legend>Depends on</legend>
              @for (other of stages(); track other.id) {
                @if (other.id !== stage.id) {
                  <label class="checkbox-row">
                    <input
                      type="checkbox"
                      [checked]="stage.dependsOn.includes(other.id)"
                      [disabled]="stage.kind === 'supervisor'"
                      (change)="onToggleDependency(stage.id, other.id, $event)"
                    />
                    {{ other.id }}
                  </label>
                }
              }
            </fieldset>

            <div class="row-actions">
              <button type="button" class="btn btn-ghost" [disabled]="i === 0" (click)="onMove(i, -1)">Up</button>
              <button type="button" class="btn btn-ghost" [disabled]="i === stages().length - 1" (click)="onMove(i, 1)">Down</button>
              <button type="button" class="btn btn-danger" (click)="onRemove(stage.id)">Remove</button>
            </div>
          </div>
        </details>
      }
    </div>
  `,
  styles: `
    .editor {
      display: flex;
      flex-direction: column;
      gap: 0.6rem;
    }
    .toolbar {
      display: flex;
      gap: 0.5rem;
    }
    .notice {
      font-size: 0.82rem;
      padding: 0.5rem 0.7rem;
      border-radius: 6px;
    }
    .notice-warn {
      color: var(--danger);
      border: 1px solid var(--danger);
      background: color-mix(in srgb, var(--danger) 8%, transparent);
    }
    .stage-card {
      gap: 0;
      padding: 0;
      overflow: hidden;
    }
    .stage-summary {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.5rem 0.7rem;
      cursor: pointer;
      list-style: none;
    }
    .stage-summary::-webkit-details-marker {
      display: none;
    }
    .index {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 1.2rem;
      height: 1.2rem;
      border-radius: 999px;
      border: 1px solid var(--border);
      font-size: 0.7rem;
      color: var(--text-muted);
    }
    .stage-id {
      font-family: var(--monospace-font);
      font-weight: 600;
    }
    .badge {
      font-size: 0.68rem;
      text-transform: uppercase;
      color: var(--accent-active);
      border: 1px solid var(--accent);
      border-radius: 999px;
      padding: 0.05rem 0.4rem;
    }
    .hint {
      margin-left: auto;
      font-size: 0.7rem;
      color: var(--text-muted);
      text-transform: uppercase;
    }
    .stage-card[open] .stage-body {
      border-top: 1px solid var(--border);
      padding: 1rem;
      display: flex;
      flex-direction: column;
      gap: 0.85rem;
      min-width: 0;
    }
    .field {
      display: flex;
      flex-direction: column;
      gap: 0.35rem;
      font-size: 0.82rem;
      color: var(--text-muted);
      min-width: 0;
      max-width: 100%;
    }
    .field legend {
      padding: 0 0.35rem;
      font-size: 0.75rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.03em;
      color: var(--text-muted);
    }
    fieldset.field,
    .field fieldset {
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      padding: 0.75rem 0.85rem;
      display: flex;
      flex-direction: column;
      gap: 0.6rem;
      min-width: 0;
    }
    textarea.control {
      font-family: var(--monospace-font);
    }
    .path-row {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-wrap: wrap;
      min-width: 0;
    }
    .path-row .control {
      flex: 1 1 12rem;
      min-width: 0;
    }
    .checkbox-row {
      display: flex;
      align-items: center;
      gap: 0.45rem;
      font-size: 0.8rem;
      color: var(--text-primary);
    }
    .checkbox-row input {
      margin: 0;
      accent-color: var(--accent);
    }
    .supervisor-note {
      color: var(--text-muted);
      font-size: 0.82rem;
      margin: 0.2rem 0;
    }
    .help {
      font-size: 0.72rem;
      color: var(--text-muted);
      line-height: 1.4;
    }
    .write-salience {
      color: var(--danger);
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .row {
      display: flex;
      gap: 0.75rem;
    }
    .row .field {
      flex: 1;
      min-width: 0;
    }
    @media (max-width: 640px) {
      .row {
        flex-direction: column;
      }
    }
    .row-actions {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-wrap: wrap;
      margin-top: 0.25rem;
      padding-top: 0.75rem;
      border-top: 1px solid var(--border);
    }
    .row-actions .btn {
      min-height: 32px;
      padding: 0.25rem 0.75rem;
      font-size: var(--font-size-xs);
    }
  `,
})
export class WorkflowStageEditorComponent {
  readonly stagesValue = input.required<readonly WorkflowStageModel[]>();
  readonly verificationProfiles = input<readonly VerificationProfileModel[] | null | undefined>(null);
  readonly stagesChange = output<WorkflowStageModel[]>();

  readonly runtimeOptions = RUNTIME_OPTIONS;
  readonly stages = signal<WorkflowStageModel[]>([]);
  readonly expanded = signal<ReadonlySet<string>>(new Set());
  readonly cycleError = signal<string | null>(null);
  readonly invalidIdError = signal<string | null>(null);
  readonly danglingError = signal<string | null>(null);

  constructor() {
    effect(() => {
      const next = [...this.stagesValue()];
      this.stages.set(next);
      this.updateErrors(next);
    });
  }

  previousStages(stageIndex: number): WorkflowStageModel[] {
    return this.stages().slice(0, stageIndex);
  }

  isPreviousStage(stageIndex: number, targetId: string): boolean {
    return this.previousStages(stageIndex).some((s) => s.id === targetId);
  }

  stageIndex(stageId: string): number {
    return this.stages().findIndex((s) => s.id === stageId);
  }

  availablePlannerStages(currentStageId: string): OrdinaryStageModel[] {
    return this.stages().filter(
      (s): s is OrdinaryStageModel => s.kind === 'ordinary' && !!s.planner && s.id !== currentStageId,
    );
  }

  isAvailablePlanner(plannerId: string, currentStageId: string): boolean {
    return this.availablePlannerStages(currentStageId).some((s) => s.id === plannerId);
  }

  availableVerificationProfiles(): string[] {
    return (this.verificationProfiles() ?? []).map((p) => p.name).filter(Boolean);
  }

  private emit(next: WorkflowStageModel[]): void {
    this.stages.set(next);
    this.updateErrors(next);
    this.stagesChange.emit(next);
  }

  private updateErrors(stages: readonly WorkflowStageModel[]): void {
    const cycle = findStageCycle(stages);
    this.cycleError.set(cycle ? `Cyclic dependencies: ${cycle.join(' → ')}` : null);
    const invalidId = findInvalidStageId(stages);
    this.invalidIdError.set(invalidId ? `Invalid or duplicate stage id: ${invalidId}` : null);
    const dangling = findDanglingDependency(stages);
    this.danglingError.set(dangling ? `Stage "${dangling.stageId}" depends on unknown stage "${dangling.dependency}"` : null);
  }

  private updateOrdinary(stageId: string, updater: (stage: OrdinaryStageModel) => OrdinaryStageModel): void {
    const next = this.stages().map((stage) => (stage.id === stageId && stage.kind === 'ordinary' ? updater(stage) : stage));
    this.emit(next);
  }

  toggleExpanded(id: string, event: Event): void {
    event.preventDefault();
    const current = new Set(this.expanded());
    if (current.has(id)) {
      current.delete(id);
    } else {
      current.add(id);
    }
    this.expanded.set(current);
  }

  onAddStage(): void {
    const next = addStage(this.stages());
    const added = next[next.length - 1];
    if (added) {
      this.expanded.set(new Set([...this.expanded(), added.id]));
    }
    this.emit(next);
  }

  onRemove(stageId: string): void {
    this.emit(removeStage(this.stages(), stageId));
  }

  onMove(index: number, direction: -1 | 1): void {
    this.emit(moveStage(this.stages(), index, direction));
  }

  onIdChange(oldId: string, event: Event): void {
    const newId = (event.target as HTMLInputElement).value;
    const next = this.stages().map((stage) => {
      if (stage.id === oldId) {
        return { ...stage, id: newId };
      }
      return { ...stage, dependsOn: stage.dependsOn.map((dep) => (dep === oldId ? newId : dep)) };
    });
    this.emit(next);
  }

  onInstructionsChange(stageId: string, event: Event): void {
    const value = (event.target as HTMLTextAreaElement).value;
    this.updateOrdinary(stageId, (stage) => ({ ...stage, instructions: value }));
  }

  onRuntimeChange(stageId: string, value: string): void {
    this.updateOrdinary(stageId, (stage) => ({ ...stage, runtime: value || undefined, model: value ? stage.model : undefined }));
  }

  onModelChange(stageId: string, value: string): void {
    this.updateOrdinary(stageId, (stage) => ({ ...stage, model: value || undefined }));
  }

  onSessionStrategyChange(stageId: string, value: string): void {
    this.updateOrdinary(stageId, (stage) => ({ ...stage, sessionStrategy: value || undefined }));
  }

  onToggleDependency(stageId: string, dependencyId: string, event: Event): void {
    const checked = (event.target as HTMLInputElement).checked;
    const next = this.stages().map((stage) => {
      if (stage.id !== stageId) {
        return stage;
      }
      const current = new Set(stage.dependsOn);
      if (checked) {
        current.add(dependencyId);
      } else {
        current.delete(dependencyId);
      }
      return { ...stage, dependsOn: [...current] };
    });
    this.emit(next);
  }

  isValidId(id: string): boolean {
    return isValidStageId(id);
  }

  addPath(stageId: string, kind: 'produces' | 'requires'): void {
    this.updateOrdinary(stageId, (stage) => ({ ...stage, [kind]: [...stage[kind], { path: '', required: true }] }));
  }

  removePath(stageId: string, kind: 'produces' | 'requires', index: number): void {
    this.updateOrdinary(stageId, (stage) => ({ ...stage, [kind]: stage[kind].filter((_, i) => i !== index) }));
  }

  onPathChange(stageId: string, kind: 'produces' | 'requires', index: number, event: Event): void {
    const path = (event.target as HTMLInputElement).value;
    this.updateOrdinary(stageId, (stage) => ({
      ...stage,
      [kind]: stage[kind].map((entry: PathEntry, i) => (i === index ? { ...entry, path } : entry)),
    }));
  }

  onPathRequiredChange(stageId: string, kind: 'produces' | 'requires', index: number, event: Event): void {
    const required = (event.target as HTMLInputElement).checked;
    this.updateOrdinary(stageId, (stage) => ({
      ...stage,
      [kind]: stage[kind].map((entry: PathEntry, i) => (i === index ? { ...entry, required } : entry)),
    }));
  }

  onPathSchemaChange(stageId: string, kind: 'produces' | 'requires', index: number, event: Event): void {
    const schema = (event.target as HTMLInputElement).value;
    this.updateOrdinary(stageId, (stage) => ({
      ...stage,
      [kind]: stage[kind].map((entry: PathEntry, i) =>
        i === index ? { ...entry, schema: schema || undefined } : entry,
      ),
    }));
  }

  writeScopesText(stage: OrdinaryStageModel): string {
    if (!stage.writeScopes || stage.writeScopes.length === 0) {
      return '';
    }
    return JSON.stringify(stage.writeScopes);
  }

  onWriteScopesChange(stageId: string, event: Event): void {
    const raw = (event.target as HTMLInputElement).value.trim();
    this.updateOrdinary(stageId, (stage) => {
      if (!raw) {
        return { ...stage, writeScopes: undefined };
      }
      try {
        const parsed = JSON.parse(raw) as unknown;
        if (Array.isArray(parsed) && parsed.every((item) => typeof item === 'string')) {
          return { ...stage, writeScopes: parsed };
        }
      } catch {
        // fall through to comma-split
      }
      return {
        ...stage,
        writeScopes: raw.split(',').map((part) => part.trim()).filter(Boolean),
      };
    });
  }

  onTogglePlanner(stageId: string, event: Event): void {
    const enabled = (event.target as HTMLInputElement).checked;
    this.updateOrdinary(stageId, (stage) =>
      enabled
        ? { ...stage, planner: { outputMode: 'plan-file', maxTodos: 100 }, planFrom: undefined }
        : { ...stage, planner: undefined },
    );
  }

  onPlannerMaxTodos(stageId: string, event: Event): void {
    const maxTodos = Number((event.target as HTMLInputElement).value);
    this.updateOrdinary(stageId, (stage) =>
      stage.planner
        ? { ...stage, planner: { ...stage.planner, maxTodos: Number.isFinite(maxTodos) ? maxTodos : undefined } }
        : stage,
    );
  }

  onPlanFromChange(stageId: string, value: string | Event): void {
    const planFrom = (
      typeof value === 'string'
        ? value
        : ((value.target as HTMLSelectElement | HTMLInputElement)?.value ?? '')
    ).trim();
    this.updateOrdinary(stageId, (stage) => ({ ...stage, planFrom: planFrom || undefined }));
  }

  onWorkspaceModeChange(stageId: string, value: string): void {
    this.updateOrdinary(stageId, (stage) => ({ ...stage, workspaceMode: value || undefined }));
  }

  onGitAccessChange(stageId: string, value: string): void {
    this.updateOrdinary(stageId, (stage) => ({ ...stage, agentGitAccess: value || undefined }));
  }

  onLoopBackToChange(stageId: string, value: string | Event): void {
    const loopBackTo = (
      typeof value === 'string'
        ? value
        : ((value.target as HTMLSelectElement | HTMLInputElement)?.value ?? '')
    ).trim();
    this.updateOrdinary(stageId, (stage) => ({
      ...stage,
      loopBackTo: loopBackTo || undefined,
      onExhausted: loopBackTo ? (stage.onExhausted || 'fail') : undefined,
    }));
  }

  onLoopCheckPathChange(stageId: string, event: Event): void {
    const path = (event.target as HTMLInputElement).value.trim();
    this.updateOrdinary(stageId, (stage) => {
      if (!path && !stage.loopCheck?.schema) {
        return { ...stage, loopCheck: undefined };
      }
      return { ...stage, loopCheck: { path, schema: stage.loopCheck?.schema } };
    });
  }

  onLoopCheckSchemaChange(stageId: string, event: Event): void {
    const schema = (event.target as HTMLInputElement).value.trim();
    this.updateOrdinary(stageId, (stage) => {
      const path = stage.loopCheck?.path ?? '';
      if (!path && !schema) {
        return { ...stage, loopCheck: undefined };
      }
      return { ...stage, loopCheck: { path, schema: schema || undefined } };
    });
  }

  onOnExhaustedChange(stageId: string, value: string | Event): void {
    const onExhausted = (
      typeof value === 'string'
        ? value
        : ((value.target as HTMLSelectElement | HTMLInputElement)?.value ?? '')
    ).trim();
    this.updateOrdinary(stageId, (stage) => ({ ...stage, onExhausted: onExhausted || undefined }));
  }

  private updateSupervisor(stageId: string, updater: (stage: SupervisorStageModel) => SupervisorStageModel): void {
    const next = this.stages().map((stage) =>
      stage.id === stageId && stage.kind === 'supervisor' ? updater(stage) : stage,
    );
    this.emit(next);
  }

  onSupervisorProfileChange(stageId: string, value: string | Event): void {
    const profile = (
      typeof value === 'string'
        ? value
        : ((value.target as HTMLSelectElement | HTMLInputElement)?.value ?? '')
    ).trim();
    this.updateSupervisor(stageId, (stage) => ({ ...stage, profile: profile || undefined }));
  }

  onSupervisorWorkspaceModeChange(stageId: string, value: string): void {
    this.updateSupervisor(stageId, (stage) => ({ ...stage, workspaceMode: value || undefined }));
  }

  onSupervisorQuestionChange(stageId: string, event: Event): void {
    const question = (event.target as HTMLInputElement).value;
    this.updateSupervisor(stageId, (stage) => ({ ...stage, question: question || undefined }));
  }

  onSupervisorChangesTargetChange(stageId: string, value: string | Event): void {
    const changesTarget = (
      typeof value === 'string'
        ? value
        : ((value.target as HTMLSelectElement | HTMLInputElement)?.value ?? '')
    ).trim();
    this.updateSupervisor(stageId, (stage) => ({ ...stage, changesTarget: changesTarget || undefined }));
  }
}
