import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { WorkflowsFacade } from '../workflows.facade';
import { ModelSelectComponent } from './model-select.component';
import { defaultsFromDetail, routingStagesFromDetail } from '../workflow-scope.helpers';
import type { WorkflowDetail, WritableWorkflowScope } from '../workflow.types';

const RUNTIME_OPTIONS = ['cursor', 'claude', 'codex', 'opencode', 'antigravity'] as const;

@Component({
  selector: 'ralph-workflow-routing-section',
  standalone: true,
  imports: [FormsModule, ModelSelectComponent],
  template: `
    <section class="routing hub-panel-card" data-testid="workflow-routing-section">
      <h3>Runtime and model routing</h3>
      <p class="hint">
        Change workflow defaults and per-stage overrides without editing raw YAML. Use inherit to follow the parent runtime chain.
      </p>

      @if (!writableScope()) {
        <p class="notice" data-testid="routing-readonly">Bundled workflows are read-only. Customize to edit routing.</p>
      } @else if (!writesEnabled()) {
        <p class="notice" data-testid="routing-writes-disabled">Workflow writes are disabled on this server.</p>
      } @else {
        <div class="defaults hub-nested-panel">
          <h4>Workflow defaults</h4>
          <label class="field">
            <span>Default runtime</span>
            <select
              class="control"
              data-testid="routing-default-runtime"
              [ngModel]="defaultsRuntime()"
              [ngModelOptions]="{ standalone: true }"
              (ngModelChange)="defaultsRuntime.set($event); markDirty()"
            >
              <option value="">inherit</option>
              @for (runtime of installedRuntimes(); track runtime) {
                <option [value]="runtime">{{ runtime }}</option>
              }
            </select>
          </label>
          @if (defaultsRuntime()) {
            <ralph-model-select
              [runtime]="defaultsRuntime()"
              [model]="defaultsModel()"
              (modelChange)="defaultsModel.set($event); markDirty()"
            />
          } @else {
            <label class="field">
              <span>Default model</span>
              <select class="control" data-testid="routing-default-model-inherit" disabled>
                <option value="">inherit</option>
              </select>
            </label>
          }
          <button type="button" class="btn btn-ghost" data-testid="routing-clear-defaults" (click)="clearDefaults()">Clear defaults</button>
        </div>

        @if (ordinaryStages().length > 0) {
          <div class="stages">
            <h4>Stage overrides</h4>
            @for (stage of ordinaryStages(); track stage.id) {
              <div class="stage-row hub-nested-panel" [attr.data-testid]="'routing-stage-' + stage.id">
                <span class="stage-id">{{ stage.id }}</span>
                <label class="field">
                  <span>Runtime</span>
                  <select
                    class="control"
                    [ngModel]="stageRuntime(stage.id)"
                    [ngModelOptions]="{ standalone: true }"
                    (ngModelChange)="setStageRuntime(stage.id, $event)"
                  >
                    <option value="">inherit</option>
                    @for (runtime of installedRuntimes(); track runtime) {
                      <option [value]="runtime">{{ runtime }}</option>
                    }
                  </select>
                </label>
                @if (stageRuntime(stage.id)) {
                  <ralph-model-select
                    [runtime]="stageRuntime(stage.id)"
                    [model]="stageModel(stage.id)"
                    (modelChange)="setStageModel(stage.id, $event)"
                  />
                }
                <button type="button" class="btn btn-ghost" [attr.data-testid]="'routing-clear-stage-' + stage.id" (click)="clearStage(stage.id)">
                  Clear
                </button>
              </div>
            }
          </div>
        }

        @if (conflict()) {
          <div class="notice notice-warn" data-testid="routing-conflict">
            <p>The file changed since it was loaded.</p>
            <button type="button" class="btn btn-secondary" data-testid="routing-reload" (click)="reload()">Reload</button>
          </div>
        }

        @if (invalidDiagnostics(); as diagnostics) {
          <p class="error" data-testid="routing-invalid-diagnostics">{{ diagnostics }}</p>
        }

        <div class="actions">
          <button
            type="button"
            class="btn btn-primary"
            data-testid="routing-save"
            [disabled]="facade.saving() || !routingDirty()"
            (click)="saveRouting()"
          >
            {{ facade.saving() ? 'Saving…' : 'Save routing' }}
          </button>
        </div>
      }
    </section>
  `,
  styles: `
    .routing {
      gap: var(--space-3);
    }
    h3,
    h4 {
      margin: 0;
      font-size: 0.9rem;
      color: var(--text-primary);
    }
    .hint,
    .notice {
      margin: 0;
      font-size: 0.82rem;
      color: var(--text-muted);
    }
    .notice-warn {
      color: var(--danger);
      border: 1px solid var(--danger);
      border-radius: 6px;
      padding: 0.5rem;
    }
    .defaults,
    .stages {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }
    .stage-row {
      display: grid;
      grid-template-columns: 6rem 1fr 1fr auto;
      gap: var(--space-2);
      align-items: end;
    }
    @media (max-width: 720px) {
      .stage-row {
        grid-template-columns: 1fr;
      }
    }
    .stage-id {
      font-family: var(--monospace-font);
      font-size: 0.8rem;
      font-weight: 600;
      align-self: center;
    }
    .field {
      display: flex;
      flex-direction: column;
      gap: 0.2rem;
      font-size: 0.78rem;
      color: var(--text-muted);
    }
    .actions {
      display: flex;
      justify-content: flex-end;
    }
    .error {
      color: var(--danger);
      font-size: 0.8rem;
      margin: 0;
    }
  `,
})
export class WorkflowRoutingSectionComponent {
  readonly facade = inject(WorkflowsFacade);

  readonly workflow = input.required<WorkflowDetail>();
  readonly writesEnabled = input(true);

  readonly defaultsRuntime = signal('');
  readonly defaultsModel = signal('');
  readonly stageOverrides = signal<Record<string, { runtime: string; model: string }>>({});
  readonly routingDirty = signal(false);
  readonly conflict = signal(false);
  readonly invalidDiagnostics = signal<string | null>(null);

  readonly writableScope = computed(() => this.facade.writableScope(this.workflow()));
  readonly installedRuntimes = computed(() => {
    const installed = this.facade.runtimes().filter((entry) => entry.installed).map((entry) => entry.id);
    const merged = new Set<string>([...RUNTIME_OPTIONS, ...installed]);
    return [...merged];
  });
  readonly ordinaryStages = computed(() => routingStagesFromDetail(this.workflow()).filter((stage) => stage.kind === 'ordinary'));

  constructor() {
    effect(() => {
      const detail = this.workflow();
      const defaults = defaultsFromDetail(detail);
      this.defaultsRuntime.set(defaults.runtime);
      this.defaultsModel.set(defaults.model);
      const overrides: Record<string, { runtime: string; model: string }> = {};
      for (const stage of routingStagesFromDetail(detail)) {
        if (stage.kind !== 'ordinary') {
          continue;
        }
        overrides[stage.id] = { runtime: stage.runtime ?? '', model: stage.model ?? '' };
      }
      this.stageOverrides.set(overrides);
      this.routingDirty.set(false);
      this.conflict.set(false);
      this.invalidDiagnostics.set(null);
    });
  }

  stageRuntime(stageId: string): string {
    return this.stageOverrides()[stageId]?.runtime ?? '';
  }

  stageModel(stageId: string): string {
    return this.stageOverrides()[stageId]?.model ?? '';
  }

  setStageRuntime(stageId: string, runtime: string): void {
    this.stageOverrides.update((current) => ({
      ...current,
      [stageId]: { runtime, model: runtime ? (current[stageId]?.model ?? '') : '' },
    }));
    this.markDirty();
  }

  setStageModel(stageId: string, model: string): void {
    this.stageOverrides.update((current) => ({
      ...current,
      [stageId]: { runtime: current[stageId]?.runtime ?? '', model },
    }));
    this.markDirty();
  }

  clearDefaults(): void {
    this.defaultsRuntime.set('');
    this.defaultsModel.set('');
    this.markDirty();
  }

  clearStage(stageId: string): void {
    this.stageOverrides.update((current) => ({
      ...current,
      [stageId]: { runtime: '', model: '' },
    }));
    this.markDirty();
  }

  markDirty(): void {
    this.routingDirty.set(true);
    this.conflict.set(false);
  }

  async reload(): Promise<void> {
    const detail = this.workflow();
    this.conflict.set(false);
    await this.facade.openDetail(detail.id, detail.scope);
  }

  async saveRouting(): Promise<void> {
    const detail = this.workflow();
    const scope = this.writableScope();
    if (!scope) {
      return;
    }
    this.invalidDiagnostics.set(null);
    const loadedDefaults = defaultsFromDetail(detail);
    const loadedStages = routingStagesFromDetail(detail).filter((stage) => stage.kind === 'ordinary');
    const patch: {
      sha256: string;
      defaults?: { runtime?: string | null; model?: string | null; clear?: boolean } | null;
      stages?: Record<string, { runtime?: string | null; model?: string | null; clear?: boolean } | null>;
    } = { sha256: detail.sha256 };

    const defaultsChanged =
      this.defaultsRuntime() !== loadedDefaults.runtime ||
      this.defaultsModel() !== loadedDefaults.model ||
      (this.defaultsRuntime() === '' && this.defaultsModel() === '' && (loadedDefaults.runtime || loadedDefaults.model));
    if (defaultsChanged) {
      if (!this.defaultsRuntime() && !this.defaultsModel() && (loadedDefaults.runtime || loadedDefaults.model)) {
        patch.defaults = { clear: true };
      } else {
        patch.defaults = {
          runtime: this.defaultsRuntime() || null,
          model: this.defaultsModel() || null,
        };
      }
    }

    const stages: Record<string, { runtime?: string | null; model?: string | null; clear?: boolean } | null> = {};
    for (const stage of loadedStages) {
      const override = this.stageOverrides()[stage.id] ?? { runtime: '', model: '' };
      const loadedRuntime = stage.runtime ?? '';
      const loadedModel = stage.model ?? '';
      if (override.runtime === loadedRuntime && override.model === loadedModel) {
        continue;
      }
      if (!override.runtime && !override.model && (loadedRuntime || loadedModel)) {
        stages[stage.id] = { clear: true };
      } else {
        stages[stage.id] = {
          runtime: override.runtime || null,
          model: override.model || null,
        };
      }
    }
    if (Object.keys(stages).length > 0) {
      patch.stages = stages;
    }

    if (!patch.defaults && !patch.stages) {
      this.routingDirty.set(false);
      return;
    }

    const result = await this.facade.patchRouting(detail.id, scope as WritableWorkflowScope, patch);
    if (result === 'ok') {
      this.routingDirty.set(false);
      return;
    }
    if (result === 'conflict') {
      this.conflict.set(true);
      return;
    }
    this.invalidDiagnostics.set(this.facade.error());
  }
}
