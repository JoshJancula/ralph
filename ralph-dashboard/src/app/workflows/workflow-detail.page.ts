import { Component, DestroyRef, OnDestroy, OnInit, inject } from '@angular/core';
import { ActivatedRoute } from '@angular/router';
import { combineLatest, map } from 'rxjs';
import type { WorkflowScope } from './workflow.types';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { WorkflowsFacade } from './workflows.facade';
import { WorkflowDetailComponent } from './components/workflow-detail.component';
import { RouteLoadStateComponent } from '../components/route-load-state/route-load-state.component';

/** Routed wrapper: loads the workflow named by the `:id` route param so a refresh or a pasted link works, per port-design.md "Component decisions". */
@Component({
  selector: 'ralph-workflow-detail-page',
  standalone: true,
  imports: [WorkflowDetailComponent, RouteLoadStateComponent],
  template: `
    <div class="page hub-page">
      @if (facade.error(); as message) {
        <h1 class="page-title">Workflow</h1>
        <p class="error" data-testid="workflow-detail-error">{{ message }}</p>
      }
      @if (facade.selected(); as workflow) {
        <ralph-workflow-detail [workflow]="workflow" />
      } @else if (!facade.error()) {
        <h1 class="page-title">Workflow</h1>
        <p class="muted">Loading workflow…</p>
        <ralph-route-load-state [loading]="true" [error]="null" [columns]="2" [rowCount]="4" />
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
      flex: 1;
      width: 100%;
      min-height: 0;
      padding-bottom: calc(var(--space-6) + var(--fab-clearance));
    }
    .muted {
      color: var(--text-muted);
    }
    .error {
      color: var(--danger);
    }
  `,
})
export class WorkflowDetailPageComponent implements OnInit, OnDestroy {
  readonly facade = inject(WorkflowsFacade);
  private readonly route = inject(ActivatedRoute);
  private readonly destroyRef = inject(DestroyRef);

  ngOnInit(): void {
    combineLatest([this.route.paramMap, this.route.queryParamMap])
      .pipe(
        map(([params, query]) => ({
          id: params.get('id'),
          scope: query.get('scope') as WorkflowScope | null,
        })),
        takeUntilDestroyed(this.destroyRef),
      )
      .subscribe(({ id, scope }) => {
        if (id) {
          void this.facade.openDetail(id, scope ?? undefined);
        }
      });
  }

  ngOnDestroy(): void {
    this.facade.stopRunsPolling();
  }
}
