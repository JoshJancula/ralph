import { Component, computed, input, output } from '@angular/core';
import { RouterLink } from '@angular/router';
import { catalogBadgeLabels } from '../workflow-catalog.helpers';
import { SCOPE_LABEL } from '../workflow-scope.helpers';
import type { WorkflowListItem } from '../workflow.types';

/** Compact catalog row: purpose, outcome, derived badges, override relationship. */
@Component({
  selector: 'ralph-workflow-card',
  standalone: true,
  imports: [RouterLink],
  template: `
    <li
      class="card surface-card"
      [class.source-project]="effectiveScope() === 'project'"
      [class.source-global]="effectiveScope() === 'global'"
      [class.source-bundled]="effectiveScope() === 'bundled'"
      [attr.data-workflow-id]="workflow().id"
      data-testid="workflow-card"
      [attr.data-requires-plan]="catalog()?.requiresSuppliedPlan ? 'true' : 'false'"
      [attr.data-has-human-gates]="catalog()?.hasHumanGates ? 'true' : 'false'"
      [attr.data-writes]="catalog()?.writes ? 'true' : 'false'"
      [attr.data-source-kind]="effectiveScope()"
    >
      <a class="card-link" [routerLink]="['/workflows', workflow().id]" [attr.data-testid]="'workflow-open-' + workflow().id">
        <span class="title-row">
          <span class="name">{{ workflow().id }}</span>
          <span
            class="scope-badge"
            [class]="'scope-' + effectiveScope()"
            data-testid="workflow-source-badge"
            >{{ effectiveScope() }}</span
          >
          @if (!workflow().editable) {
            <span class="readonly-badge" data-testid="workflow-readonly-badge">read-only</span>
          }
        </span>
        <span class="purpose" data-testid="workflow-purpose">{{ catalog()?.purpose || workflow().overview || 'No overview' }}</span>
        <span class="outcome" data-testid="workflow-outcome">{{ catalog()?.expectedOutcome || 'Completed stage outputs' }}</span>
        <span class="badges" data-testid="workflow-catalog-badges">
          @for (label of badges(); track label) {
            <span class="meta-badge" [attr.data-badge]="label">{{ label }}</span>
          }
        </span>
        @if (workflow().inheritsFrom; as inherit) {
          <span class="inherit-hint" data-testid="workflow-inherit-hint">
            Overrides {{ scopeLabel(inherit.scope) }}: {{ inherit.explanation }}
          </span>
        } @else if (layerHint(); as hint) {
          <span class="layers-hint" data-testid="workflow-layers-hint">{{ hint }}</span>
        }
      </a>
      <div class="actions">
        <button
          type="button"
          class="btn btn-primary"
          data-testid="run-workflow-now"
          [disabled]="triggering()"
          (click)="onRun($event)"
        >
          {{ triggering() ? 'Starting…' : 'Start' }}
        </button>
        <a class="btn btn-secondary" [routerLink]="['/workflows', workflow().id]" data-testid="workflow-open">Open</a>
      </div>
    </li>
  `,
  styles: `
    :host {
      display: block;
    }
    .card {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      align-items: center;
      gap: var(--space-4);
      padding: 0;
      overflow: hidden;
      box-sizing: border-box;
      width: 100%;
    }
    .card.source-project {
      border-color: color-mix(in srgb, var(--accent) 40%, var(--ion-color-step-200, #30363d));
    }
    .card.source-global {
      background: var(--ion-color-step-100, #161b22);
    }
    .card.source-bundled {
      background: var(--ion-color-step-50, #0d1117);
    }
    .card:hover {
      border-color: var(--ion-color-step-300, #6e7681);
      box-shadow: 0 10px 28px rgba(0, 0, 0, 0.22);
    }
    .card-link {
      min-width: 0;
      display: flex;
      flex-direction: column;
      gap: 0.35rem;
      padding: 1rem 1.15rem;
      cursor: pointer;
      color: inherit;
      text-decoration: none;
    }
    .card-link:focus-visible {
      outline: var(--focus-ring-width) solid var(--focus-ring-color);
      outline-offset: calc(-1 * var(--focus-ring-offset));
    }
    .title-row {
      display: flex;
      align-items: center;
      gap: var(--space-2);
      flex-wrap: wrap;
      line-height: normal;
    }
    .name {
      font-weight: 650;
      color: var(--text-primary);
      font-family: var(--monospace-font);
      font-size: var(--font-size-md);
      overflow-wrap: anywhere;
      letter-spacing: -0.01em;
    }
    .card-link:hover .name {
      text-decoration: underline;
    }
    .purpose {
      font-size: var(--font-size-sm);
      line-height: var(--line-height-body);
      color: var(--text-primary);
      display: -webkit-box;
      -webkit-line-clamp: 1;
      -webkit-box-orient: vertical;
      overflow: hidden;
      overflow-wrap: anywhere;
    }
    .outcome {
      font-size: var(--font-size-xs);
      line-height: var(--line-height-body);
      color: var(--text-muted);
      overflow-wrap: anywhere;
    }
    .badges {
      display: flex;
      flex-wrap: wrap;
      gap: 0.35rem;
      margin-top: var(--space-1);
    }
    .meta-badge {
      text-transform: none;
      letter-spacing: 0;
      background: var(--surface-hover, transparent);
      padding: 0.15rem 0.5rem;
      border-radius: var(--radius-sm);
      border: 1px solid var(--border);
      font-size: var(--font-size-xs);
      line-height: 1.25;
      white-space: nowrap;
    }
    .meta-badge[data-badge='Human gates'],
    .meta-badge[data-badge='Requires supplied plan'] {
      color: var(--info-text);
      background: var(--info-bg);
      border-color: transparent;
    }
    .inherit-hint,
    .layers-hint {
      font-size: var(--font-size-xs);
      line-height: var(--line-height-body);
      color: var(--text-muted);
    }
    .actions {
      display: flex;
      align-items: center;
      gap: var(--space-2);
      flex-shrink: 0;
      padding-right: 1.15rem;
      white-space: nowrap;
    }
    .actions .btn {
      min-width: 4.5rem;
      text-align: center;
      justify-content: center;
      white-space: nowrap;
    }
    @media (max-width: 768px) {
      .card {
        grid-template-columns: minmax(0, 1fr);
        align-items: stretch;
      }
      .card-link {
        padding-bottom: var(--space-2);
      }
      .actions {
        padding: 0 1.15rem 1rem;
      }
      .actions .btn {
        flex: 1;
      }
    }
  `,
})
export class WorkflowCardComponent {
  readonly workflow = input.required<WorkflowListItem>();
  readonly triggering = input(false);
  readonly runNow = output<string>();

  readonly effectiveScope = computed(() => this.workflow().effectiveScope ?? this.workflow().scope);
  readonly catalog = computed(() => this.workflow().catalog);
  readonly badges = computed(() => catalogBadgeLabels(this.catalog()));
  readonly layerHint = computed(() => {
    if (this.workflow().inheritsFrom) {
      return null;
    }
    const layers = this.workflow().availableScopes;
    if (!layers || layers.length <= 1) {
      return null;
    }
    const names = layers.map((entry) => SCOPE_LABEL[entry.scope]).join(', ');
    return `Also defined in: ${names}`;
  });

  scopeLabel(scope: string): string {
    return SCOPE_LABEL[scope as keyof typeof SCOPE_LABEL] ?? scope;
  }

  onRun(event: Event): void {
    event.stopPropagation();
    event.preventDefault();
    this.runNow.emit(this.workflow().id);
  }
}
