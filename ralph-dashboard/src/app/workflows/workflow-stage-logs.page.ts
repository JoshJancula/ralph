import { ChangeDetectionStrategy, Component, OnDestroy, OnInit, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { Subscription } from 'rxjs';
import { ApiService } from '../services/api.service';
import { WorkspaceSelectorService } from '../services/workspace-selector.service';
import { ErrorModalComponent } from '../components/error-modal/error-modal.component';

@Component({
  selector: 'ralph-workflow-stage-logs-page',
  standalone: true,
  imports: [CommonModule, RouterLink, ErrorModalComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="page hub-page">
      <a class="back-link" [routerLink]="['/workflows/runs', runId()]">Back to run</a>
      <header class="page-header">
        <div>
          <h1 class="page-title">Stage logs</h1>
          <p class="page-lede">{{ stageId() }} · attempt {{ attempt() }} · combined agent and supervisor stream.</p>
        </div>
        <button class="btn btn-secondary" (click)="load()">Refresh</button>
      </header>
      @if (loading()) {
        <p class="state">Loading stage logs…</p>
      } @else if (error()) {
        <div class="error-embed" role="alert">
          <ralph-error-modal class="is-embedded" [error]="error()" [embedded]="true" [showHeader]="false" />
        </div>
      } @else if (!content()) {
        <p class="state">No log output has been recorded for this stage attempt.</p>
      } @else {
        <pre class="log-output">{{ content() }}</pre>
      }
    </div>
  `,
  styles: `
    :host { display:flex; flex:1; min-height:0; }
    .page { background:var(--surface); }
    .state { color:var(--text-muted); }
    .error-embed { max-width: 40rem; }
    .log-output {
      margin:0; padding:var(--space-4); overflow:auto; border:1px solid var(--border);
      border-radius:var(--radius-md); background:var(--surface-secondary); color:var(--text-primary);
      font-family:var(--monospace-font); font-size:var(--font-size-sm); line-height:1.5;
      white-space:pre-wrap; word-break:break-word;
    }
  `,
})
export class WorkflowStageLogsPageComponent implements OnInit, OnDestroy {
  private readonly api = inject(ApiService);
  private readonly route = inject(ActivatedRoute);
  private readonly workspace = inject(WorkspaceSelectorService);
  private subscription: Subscription | null = null;

  readonly runId = signal('');
  readonly stageId = signal('');
  readonly attempt = signal(1);
  readonly loading = signal(false);
  readonly error = signal<unknown>(null);
  readonly content = signal('');

  ngOnInit(): void {
    this.runId.set(this.route.snapshot.paramMap.get('runId') ?? '');
    this.stageId.set(this.route.snapshot.paramMap.get('stageId') ?? '');
    this.attempt.set(Math.max(1, Number(this.route.snapshot.queryParamMap.get('attempt') ?? 1)));
    this.load();
  }

  ngOnDestroy(): void {
    this.subscription?.unsubscribe();
  }

  load(): void {
    this.subscription?.unsubscribe();
    this.loading.set(true);
    this.error.set(null);
    const selected = this.workspace.selectedWorkspacePath();
    const workspaceRoot = this.workspace.workspaces().find((item) => item.projectRoot === selected)?.workspaceRoot;
    this.subscription = this.api.fetchWorkflowStageLogs(this.runId(), this.stageId(), this.attempt(), workspaceRoot).subscribe({
      next: (response) => {
        this.content.set(response.content);
        this.loading.set(false);
      },
      error: (err) => {
        this.error.set(err);
        this.loading.set(false);
      },
    });
  }
}
