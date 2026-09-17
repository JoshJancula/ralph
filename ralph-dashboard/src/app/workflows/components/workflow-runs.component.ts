import { Component, computed, input } from '@angular/core';
import { RouterLink } from '@angular/router';
import type { RunListItem } from '../workflow.types';

const LIVE_STATES = new Set(['running', 'queued', 'waiting']);
const FAILED_STATES = new Set(['failed', 'stale', 'cancelled']);

/** Ported from trade-beacon's workflow-runs.component.ts against Ralph's run-list shape (state, createdAt, no token count — see port-design.md). */
@Component({
  selector: 'ralph-workflow-runs',
  standalone: true,
  imports: [RouterLink],
  template: `
    <section class="runs" aria-labelledby="workflow-runs-heading">
      <div class="head">
        <h3 id="workflow-runs-heading">Runs</h3>
        @if (liveCount() > 0) {
          <span class="pill pill-live" data-testid="workflow-runs-live">{{ liveCount() }} in progress</span>
        }
      </div>

      @if (loading() && runs().length === 0) {
        <p class="muted" data-testid="workflow-runs-loading">Loading runs…</p>
      } @else if (runs().length === 0) {
        <p class="muted empty-hint" data-testid="workflow-runs-empty">This workflow has not run yet. Use Start to begin one.</p>
      } @else {
        <ul class="run-list" data-testid="workflow-runs-list">
          @for (run of runs(); track run.runId) {
            <li class="run-row" [attr.data-testid]="'workflow-run-' + run.runId">
              <a class="run-link" [routerLink]="['/workflows', 'runs', run.runId]">
                <span class="row-title">
                  <span class="status-badge pill" [class]="pillClass(run.state)">{{ run.state }}</span>
                  <span class="run-id">{{ run.runId }}</span>
                </span>
                <span class="row-meta">
                  {{ run.createdAt }}
                  @if (run.task) {
                    <span> · {{ run.task }}</span>
                  }
                </span>
              </a>
            </li>
          }
        </ul>
      }
    </section>
  `,
  styles: `
    .runs {
      display: flex;
      flex-direction: column;
      gap: var(--space-3);
    }
    .head {
      display: flex;
      align-items: center;
      gap: var(--space-2);
    }
    h3 {
      margin: 0;
      font-size: var(--font-size-sm);
      font-weight: 600;
      letter-spacing: var(--letter-label);
      text-transform: uppercase;
      color: var(--text-muted);
    }
    .muted {
      color: var(--text-muted);
      font-size: var(--font-size-sm);
    }
    .empty-hint {
      padding: var(--space-4);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      background: var(--surface);
    }
    .run-list {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
    }
    .run-row {
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      background: var(--surface);
    }
    .run-link {
      display: flex;
      flex-direction: column;
      gap: 0.15rem;
      padding: 0.6rem 0.75rem;
      color: inherit;
      text-decoration: none;
    }
    .run-link:hover {
      background: var(--surface-hover);
    }
    .row-title {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    .run-id {
      font-family: var(--monospace-font);
      font-size: 0.85rem;
    }
    .row-meta {
      font-size: 0.78rem;
      color: var(--text-muted);
    }
    .pill {
      font-size: 0.7rem;
      padding: 0.1rem 0.45rem;
      border-radius: 999px;
      border: 1px solid var(--border);
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.02em;
    }
    .pill-live {
      color: var(--accent-active);
      border-color: var(--accent);
    }
    .pill-failed {
      color: var(--danger);
      border-color: var(--danger);
    }
    .pill-succeeded {
      color: var(--text-primary);
      border-color: var(--border);
    }
  `,
})
export class WorkflowRunsComponent {
  readonly runs = input.required<readonly RunListItem[]>();
  readonly loading = input(false);

  readonly liveCount = computed(() => this.runs().filter((run) => LIVE_STATES.has(run.state)).length);

  pillClass(state: string): string {
    if (LIVE_STATES.has(state)) return 'pill-live';
    if (FAILED_STATES.has(state)) return 'pill-failed';
    if (state === 'succeeded') return 'pill-succeeded';
    return '';
  }
}
