import { Component, computed, effect, inject, input, output, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { WorkflowsFacade } from '../workflows.facade';
import type { ModelDescriptor } from '../workflow.types';

const CUSTOM_SENTINEL = '__custom__';

/**
 * Ported from trade-beacon's model-select.component.ts, engine-agnostic
 * logic kept verbatim: the ngModel-not-[value] selected-option fix (a raw
 * [value] binding is applied before the @for options exist and gets
 * dropped), the custom-model sentinel flow, and the stranded-model-on-
 * runtime-switch handling. Swapped WorkflowsFacade.loadModels's backing
 * call for /api/workflow-runtimes/:runtime/models (see port-design.md).
 */
@Component({
  selector: 'ralph-model-select',
  standalone: true,
  imports: [FormsModule],
  template: `
    <label class="field">
      <span>Model</span>
      <select
        class="control"
        data-testid="workflow-model-select"
        [ngModel]="selectValue()"
        [ngModelOptions]="{ standalone: true }"
        [disabled]="disabled() || loading()"
        (ngModelChange)="onSelectValue($event)"
      >
        @if (loading()) {
          <option value="">Loading models…</option>
        } @else {
          @for (entry of models(); track entry.id) {
            <option [value]="entry.id">{{ entry.label }}</option>
          }
          <option [value]="CUSTOM_SENTINEL">Custom…</option>
        }
      </select>
    </label>
    @if (isCustom() && !loading()) {
      <label class="field">
        <span>Custom model name</span>
        <input
          type="text"
          class="control"
          data-testid="workflow-model-custom-input"
          placeholder="e.g. claude-opus-4-5"
          [value]="customText()"
          (input)="onCustomInput($event)"
          autocomplete="off"
        />
      </label>
    }
  `,
  styles: `
    .field {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
      font-size: 0.82rem;
      color: var(--text-muted);
    }
  `,
})
export class ModelSelectComponent {
  readonly CUSTOM_SENTINEL = CUSTOM_SENTINEL;
  private readonly facade = inject(WorkflowsFacade);

  readonly runtime = input.required<string>();
  readonly model = input.required<string>();
  readonly disabled = input(false);
  readonly modelChange = output<string>();

  readonly models = signal<readonly ModelDescriptor[]>([]);
  readonly loading = signal(false);
  readonly customText = signal('');
  private readonly customMode = signal(false);
  private lastRuntime: string | null = null;
  private reloadGeneration = 0;

  readonly selectValue = computed(() => {
    if (this.customMode()) return CUSTOM_SENTINEL;
    const m = this.model();
    if (!m) return '';
    return this.models().some((entry) => entry.id === m) ? m : CUSTOM_SENTINEL;
  });

  readonly isCustom = computed(() => this.selectValue() === CUSTOM_SENTINEL);

  constructor() {
    effect(() => {
      const m = this.model();
      if (m && !this.models().some((entry) => entry.id === m)) {
        this.customText.set(m);
      }
    });

    effect(() => {
      const runtimeId = this.runtime();
      void this.reload(runtimeId);
    });
  }

  private async reload(runtimeId: string): Promise<void> {
    const generation = ++this.reloadGeneration;
    const isRuntimeSwitch = this.lastRuntime !== null && this.lastRuntime !== runtimeId;
    this.lastRuntime = runtimeId;
    if (!runtimeId || runtimeId === 'inherit') {
      this.models.set([]);
      this.loading.set(false);
      this.customMode.set(false);
      return;
    }
    if (isRuntimeSwitch) {
      this.customMode.set(false);
      this.customText.set('');
    }
    this.loading.set(true);
    try {
      const models = await this.facade.loadModels(runtimeId);
      if (generation !== this.reloadGeneration || this.runtime() !== runtimeId) {
        return;
      }
      this.models.set(models);
      if (models.length === 0) {
        return;
      }
      const current = this.model();
      const stranded = isRuntimeSwitch && !this.customMode() && !models.some((entry) => entry.id === current);
      if (!current || stranded) {
        this.modelChange.emit(models[0]?.id ?? '');
      }
    } finally {
      if (generation === this.reloadGeneration) {
        this.loading.set(false);
      }
    }
  }

  onSelectValue(value: string): void {
    if (value === CUSTOM_SENTINEL) {
      this.customMode.set(true);
      const typed = this.customText().trim();
      if (typed) {
        this.modelChange.emit(typed);
      }
      return;
    }
    this.customMode.set(false);
    if (value !== this.model()) {
      this.modelChange.emit(value);
    }
  }

  onCustomInput(event: Event): void {
    const value = (event.target as HTMLInputElement).value;
    this.customText.set(value);
    this.modelChange.emit(value);
  }
}
