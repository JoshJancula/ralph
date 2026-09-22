import { Component, OnDestroy, OnInit, computed, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { WorkflowsFacade } from './workflows.facade';
import { CapabilitiesService } from './capabilities.service';
import { WorkflowCardComponent } from './components/workflow-card.component';
import { RouteLoadStateComponent } from '../components/route-load-state/route-load-state.component';
import { groupWorkflowsByEffectiveScope } from './workflow-catalog.helpers';
import { markInventoryUsable } from '../utils/perf-diagnostics';
import type { WorkflowScope } from './workflow.types';

const SCOPE_ORDER: readonly WorkflowScope[] = ['project', 'global', 'bundled'];
const SCOPE_LABEL: Record<WorkflowScope, string> = {
  project: 'Project',
  global: 'Global',
  bundled: 'Bundled',
};
const SCOPE_BLURB: Record<WorkflowScope, string> = {
  project: 'This workspace. Highest precedence.',
  global: 'Shared across projects.',
  bundled: 'Framework defaults. Read-only until customized.',
};

/** Searchable catalog grouped by source precedence (project > global > bundled). */
@Component({
  selector: 'ralph-workflows-list-page',
  standalone: true,
  imports: [RouterLink, FormsModule, WorkflowCardComponent, RouteLoadStateComponent],
  template: `
    <div class="page hub-page" data-testid="workflows-page">
      <div class="head page-header">
        <div class="head-text">
          <h1 class="page-title">Workflows</h1>
          <p class="lede page-lede" data-testid="workflows-precedence-lede">
            Project overrides global, which overrides bundled. Bundled stays read-only.
          </p>
        </div>
        @if (capabilities.capabilities().workflowWrites) {
          <a class="btn btn-primary" routerLink="/workflows/new" data-testid="workflows-new">New workflow</a>
        }
      </div>

      <div class="hub-toolbar">
        <label class="search-label" data-testid="workflows-search-label">
          <span class="visually-hidden">Search workflows</span>
          <input
            type="search"
            class="search-input"
            placeholder="Search by id, purpose, plan, gates, writes…"
            data-testid="workflows-search"
            [ngModel]="facade.catalogSearch()"
            (ngModelChange)="facade.setCatalogSearch($event)"
          />
        </label>
      </div>

      <ralph-route-load-state
        [loading]="facade.loading() && !facade.loaded()"
        [error]="facade.error()"
        [columns]="1"
        [rowCount]="6"
        (retry)="retryLoad()"
      />

      @if ((!facade.loading() || facade.loaded()) && !facade.error()) {
        @if (facade.workflows().length === 0) {
          <div class="empty-state" data-testid="workflows-empty">
            <p>No workflows found.</p>
            <p class="empty-hint">Bundled definitions appear after install. Project and global copies override them.</p>
          </div>
        } @else if (filteredCount() === 0) {
          <div class="empty-state" data-testid="workflows-search-empty">
            <p>No workflows match your search.</p>
            <p class="empty-hint">Try an id, purpose, or a catalog term such as gates or writes.</p>
          </div>
        } @else {
          <div class="inventory" data-testid="workflows-inventory">
            @for (scope of scopeOrder; track scope) {
              @if (groupedByScope().get(scope); as group) {
                @if (group.length > 0) {
                  <section
                    class="scope-group"
                    [class.scope-group-project]="scope === 'project'"
                    [class.scope-group-global]="scope === 'global'"
                    [class.scope-group-bundled]="scope === 'bundled'"
                    [attr.data-testid]="'workflows-scope-' + scope"
                  >
                    <div class="scope-head">
                      <h3>
                        {{ scopeLabel(scope) }}
                        <span class="scope-count">{{ group.length }}</span>
                      </h3>
                      <p class="scope-blurb">{{ scopeBlurb(scope) }}</p>
                    </div>
                    <ul class="card-list">
                      @for (workflow of group; track workflow.id) {
                        <ralph-workflow-card
                          [workflow]="workflow"
                          [triggering]="facade.isTriggering(workflow.id)"
                          (runNow)="onRunNow($event)"
                        />
                      }
                    </ul>
                  </section>
                }
              }
            }
          </div>
        }
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
      gap: var(--space-4);
      width: 100%;
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      padding-bottom: calc(var(--space-6) + var(--fab-clearance, 4.5rem));
    }
    .head {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: var(--space-4);
      margin-bottom: 0;
    }
    .head-text {
      display: flex;
      flex-direction: column;
      gap: var(--space-1);
      min-width: 0;
    }
    .hub-toolbar {
      margin-bottom: 0;
    }
    .search-label {
      display: block;
      flex: 1;
      min-width: 0;
    }
    .search-input {
      width: 100%;
      box-sizing: border-box;
      padding: 0.6rem 0.85rem;
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      background: var(--surface);
      color: var(--text-primary);
      font: inherit;
      font-size: var(--font-size-sm);
      outline: none;
      transition: border-color 0.15s ease;
    }
    .search-input:focus {
      border-color: var(--accent);
      outline: var(--focus-ring-width) solid var(--focus-ring-color);
      outline-offset: 1px;
    }
    .empty-hint {
      margin-top: var(--space-2);
      font-size: var(--font-size-sm);
    }
    .inventory {
      display: flex;
      flex-direction: column;
      gap: var(--space-6);
    }
    .scope-group {
      display: flex;
      flex-direction: column;
      gap: var(--space-3);
    }
    .scope-head h3 {
      margin: 0;
      font-size: var(--font-size-xs);
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: var(--letter-label);
      color: var(--text-muted);
    }
    .scope-count {
      margin-left: var(--space-1);
      font-variant-numeric: tabular-nums;
      color: var(--text-secondary);
    }
    .scope-blurb {
      margin: var(--space-1) 0 0;
      font-size: var(--font-size-xs);
      line-height: var(--line-height-body);
      color: var(--text-muted);
    }
    .card-list {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: var(--space-3);
    }
    @media (max-width: 720px) {
      .head {
        flex-wrap: wrap;
      }
      .head .btn {
        flex-shrink: 0;
      }
    }
  `,
})
export class WorkflowsListPageComponent implements OnInit, OnDestroy {
  readonly facade = inject(WorkflowsFacade);
  readonly capabilities = inject(CapabilitiesService);

  readonly scopeOrder = SCOPE_ORDER;

  readonly filteredCount = computed(() => this.facade.filteredWorkflows().length);

  readonly groupedByScope = computed(() => groupWorkflowsByEffectiveScope(this.facade.filteredWorkflows()));

  ngOnInit(): void {
    void this.facade.load().then(() => {
      if (!this.facade.error()) {
        markInventoryUsable('workflows');
      }
    });
    this.capabilities.load();
  }

  ngOnDestroy(): void {
    this.facade.stopRunsPolling();
  }

  retryLoad(): void {
    void this.facade.load().then(() => {
      if (!this.facade.error()) {
        markInventoryUsable('workflows');
      }
    });
  }

  scopeLabel(scope: WorkflowScope): string {
    return SCOPE_LABEL[scope];
  }

  scopeBlurb(scope: WorkflowScope): string {
    return SCOPE_BLURB[scope];
  }

  onRunNow(id: string): void {
    if (this.facade.needsProjectSelection()) {
      this.facade.requireProjectSelection();
      return;
    }
    void this.facade.start(id, { task: `Run ${id}` });
  }
}
