import { Component, DestroyRef, OnInit, computed, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { CapabilitiesService } from './capabilities.service';
import { WorkflowsFacade } from './workflows.facade';
import type {
  ActionDecision,
  OperatorNextAction,
  RunActionDetail,
  RunStatus,
  RunTimelineEvent,
  StageMapEntry,
} from './workflow.types';

const DECISIONS: readonly ActionDecision[] = ['approve', 'request-changes', 'cancel', 'answer'];
const MESSAGE_DECISIONS: ReadonlySet<string> = new Set(['request-changes', 'answer']);

function basename(path: string | null | undefined): string | null {
  if (!path) {
    return null;
  }
  const parts = path.split('/').filter(Boolean);
  return parts.length > 0 ? parts[parts.length - 1]! : path;
}

@Component({
  selector: 'ralph-workflow-run-detail-page',
  standalone: true,
  imports: [CommonModule, FormsModule, RouterLink],
  template: `
    <div class="page hub-page" data-testid="run-detail-page">
      <a class="back-link" [routerLink]="workflowId() ? ['/workflows', workflowId()] : ['/runs']" data-testid="run-back">
        Back
      </a>

      <div class="run-header page-header">
        <h1 class="page-title" data-testid="run-detail-title">Run {{ runId() }}</h1>
        @if (runState(); as state) {
          <span class="status-badge state-badge" [class]="'state-' + state" data-testid="run-state">{{ state }}</span>
        }
      </div>

      @if (task(); as taskText) {
        <p class="run-task" data-testid="run-detail-task">{{ taskText }}</p>
      }

      @if (!capabilities.capabilities().workflowRuns) {
        <p class="notice" data-testid="run-controls-disabled">
          The server is not bound to a loopback host, so run controls are disabled.
        </p>
      } @else {
        @if (operatorNext(); as next) {
          <section
            class="next-action-panel hub-panel-card"
            [class.disabled]="!next.enabled"
            [class.next-resume]="next.kind === 'resume'"
            [class.next-reset]="next.kind === 'reset'"
            [class.next-respond]="next.kind === 'respond'"
            data-testid="next-action-panel"
          >
            <h3>Next action</h3>
            <p class="action-label" data-testid="next-action-label">{{ next.label }}</p>
            <p class="action-text" data-testid="next-action-description">{{ next.description }}</p>
            @if (next.disabledReason) {
              <p class="disabled-reason" data-testid="next-action-disabled-reason">{{ next.disabledReason }}</p>
            }
            <div class="next-action-controls">
              @if (next.kind === 'resume') {
                <button
                  type="button"
                  class="btn btn-primary"
                  data-testid="run-resume-primary"
                  [disabled]="!next.enabled"
                  (click)="doResume()"
                >
                  Resume
                </button>
              }
              @if (next.kind === 'reset') {
                <button
                  type="button"
                  class="btn btn-primary"
                  data-testid="run-reset-primary"
                  [disabled]="!next.enabled || !next.resetStageId"
                  (click)="doReset(next.resetStageId)"
                >
                  Reset {{ next.resetStageId || 'stage' }}
                </button>
              }
              @if (next.kind === 'respond' && next.requestId) {
                <p class="hint" data-testid="next-action-respond-hint">Use the pending action card below to respond.</p>
              }
            </div>
          </section>
        }

        <section class="pending-actions" data-testid="pending-actions-panel">
          <h3>Operator actions</h3>
          @if (actions().length === 0) {
            <p class="muted" data-testid="pending-actions-empty">No action requests.</p>
          } @else {
            @for (action of actions(); track action.requestId) {
              <div
                class="action-card"
                [class.action-disabled]="!action.enabled"
                [class.action-primary]="isPrimaryActionCard(action)"
                [attr.data-testid]="'pending-action-' + action.requestId"
                [attr.data-status]="action.status"
              >
                <p class="question">{{ action.question }}</p>
                <p class="action-meta">
                  {{ action.kind }}
                  @if (action.stageId) {
                    <span> · stage {{ action.stageId }}</span>
                  }
                  <span class="action-status" [attr.data-testid]="'action-status-' + action.requestId">{{ action.status }}</span>
                </p>
                @if (action.decision) {
                  <p class="persisted-decision" [attr.data-testid]="'action-decision-' + action.requestId">
                    Persisted decision: {{ action.decision }}
                    @if (action.message) {
                      <span> — {{ action.message }}</span>
                    }
                    @if (action.status === 'consumed') {
                      <span> (consumed; replay refused)</span>
                    }
                    @if (action.status === 'answered') {
                      <span> (answered; resume to consume)</span>
                    }
                  </p>
                }
                @if (action.disabledReason) {
                  <p class="disabled-reason" [attr.data-testid]="'action-disabled-' + action.requestId">{{ action.disabledReason }}</p>
                }
                <div class="respond-row">
                  @for (decision of decisionsFor(action); track decision; let i = $index) {
                    <button
                      type="button"
                      [class]="decisionButtonClass(action, i)"
                      [attr.data-testid]="'respond-' + action.requestId + '-' + decision"
                      [disabled]="!action.enabled"
                      (click)="respond(action.requestId, decision)"
                    >
                      {{ decision }}
                    </button>
                  }
                </div>
                @if (messageNeeded().has(action.requestId)) {
                  <input
                    class="control"
                    type="text"
                    placeholder="message (required)"
                    [attr.data-testid]="'respond-message-' + action.requestId"
                    [(ngModel)]="messages[action.requestId]"
                    [name]="'message-' + action.requestId"
                  />
                  <button
                    type="button"
                    class="btn btn-primary"
                    [attr.data-testid]="'respond-send-' + action.requestId"
                    [disabled]="!action.enabled || !messages[action.requestId]?.trim()"
                    (click)="sendResponseWithMessage(action.requestId)"
                  >
                    Send
                  </button>
                }
              </div>
            }
          }
        </section>

        <div class="actions secondary-actions">
          @if (!confirmingCancel()) {
            <button type="button" class="btn btn-danger" data-testid="run-cancel" (click)="confirmingCancel.set(true)" [disabled]="isTerminal()">
              Cancel run
            </button>
          } @else {
            <span class="confirm-row" data-testid="run-cancel-confirm">
              Cancel this run?
              <button type="button" class="btn btn-ghost" data-testid="run-cancel-no" (click)="confirmingCancel.set(false)">No</button>
              <button type="button" class="btn btn-danger" data-testid="run-cancel-yes" (click)="doCancel()">Yes, cancel</button>
            </span>
          }
          <button
            type="button"
            class="btn btn-secondary"
            data-testid="run-resume"
            (click)="doResume()"
            [disabled]="!canResume()"
            [attr.title]="resumeDisabledReason()"
          >
            Resume
          </button>
          @if (canShowReset()) {
            <button
              type="button"
              class="btn btn-secondary"
              data-testid="run-reset"
              (click)="doReset(operatorNext()?.resetStageId ?? null)"
              [disabled]="!operatorNext()?.enabled || !operatorNext()?.resetStageId"
            >
              Reset
            </button>
          }
          @if (resumeDisabledReason(); as reason) {
            <span class="control-hint" data-testid="resume-disabled-reason">{{ reason }}</span>
          }
        </div>

        @if (stages().length > 0) {
          <section class="stages-section" data-testid="stages-section">
            <h3>Stage map</h3>
            <div class="stages-grid">
              @for (stage of stages(); track stage.id) {
                <div class="stage-card hub-panel-card" [class]="'stage-status-' + stage.state" [attr.data-testid]="'stage-' + stage.id">
                  <div class="stage-header">
                    <span class="stage-id">{{ stage.id }}</span>
                    <span class="stage-status">{{ stage.state }}</span>
                  </div>
                  <p class="stage-kind">{{ stage.stageKind }}</p>
                  @if (stage.attempt > 0) {
                    <p class="stage-attempt" data-testid="stage-attempt">
                      Attempt {{ stage.attempt }}
                      @if (stage.reworkRound > 1) {
                        <span> (rework round {{ stage.reworkRound }})</span>
                      }
                    </p>
                  }
                  @if (stage.todoProgress; as todos) {
                    <p class="stage-todos" data-testid="stage-todo-progress">
                      TODOs {{ todos.completed }}/{{ todos.total }}
                      @if (todos.currentTodoId) {
                        <span> — current {{ todos.currentTodoId }}</span>
                      }
                    </p>
                  }
                  @if (stage.sourcePlanPath || stage.controlPlanPath) {
                    <div class="plan-paths" data-testid="stage-plan-paths">
                      @if (stage.sourcePlanPath) {
                        <p class="plan-path immutable">
                          <span class="path-label">Source (immutable)</span>
                          {{ planBasename(stage.sourcePlanPath) }}
                        </p>
                      }
                      @if (stage.controlPlanPath) {
                        <p class="plan-path control">
                          <span class="path-label">Control (mutable)</span>
                          {{ planBasename(stage.controlPlanPath) }}
                        </p>
                      }
                    </div>
                  }
                  @if (stage.requiredEvidence.length > 0) {
                    <p class="stage-evidence" data-testid="stage-required-evidence">
                      Required: {{ stage.requiredEvidence.join(', ') }}
                    </p>
                  }
                  @if (stage.producedEvidence.length > 0) {
                    <p class="stage-evidence" data-testid="stage-produced-evidence">
                      Evidence: {{ stage.producedEvidence.join(', ') }}
                    </p>
                  }
                  @if (stage.actionRequestId) {
                    <p class="stage-request" data-testid="stage-action-request">
                      Request {{ stage.actionRequestId }}
                      @if (stage.requestState) {
                        <span> ({{ stage.requestState }})</span>
                      }
                    </p>
                  }
                  @if (stage.summary) {
                    <p class="stage-summary">{{ stage.summary }}</p>
                  }
                  @if (stage.nextPermittedAction) {
                    <p class="stage-next" data-testid="stage-next-action">{{ stage.nextPermittedAction }}</p>
                  }
                  @if (stage.attempt > 0) {
                    <div class="stage-log" data-testid="stage-log-scope">
                      <span>Logs: {{ stage.logScope || 'stage attempt ' + stage.attempt }}</span>
                      <a class="btn btn-ghost" [routerLink]="['/workflows/runs', runId(), 'stages', stage.id, 'logs']" [queryParams]="{ attempt: stage.attempt || 1 }">View logs</a>
                    </div>
                  }
                </div>
              }
            </div>
          </section>
        }

        @if (timeline().length > 0) {
          <section class="timeline-section" data-testid="timeline-section">
            <h3>Timeline</h3>
            <div class="timeline">
              @for (event of timeline(); track event.id) {
                <div class="timeline-event" [class]="'event-type-' + event.type" [attr.data-testid]="'event-' + event.type">
                  <div class="event-time">{{ formatTime(event.timestamp) }}</div>
                  <div class="event-content">
                    <p class="event-message">{{ event.message }}</p>
                    @if (event.stageId) {
                      <p class="event-stage">Stage: {{ event.stageId }}</p>
                    }
                  </div>
                </div>
              }
            </div>
          </section>
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
      max-width: 60rem;
      flex: 1;
      min-height: 0;
      overflow-x: hidden;
      overflow-y: auto;
      padding-bottom: var(--space-6);
    }
    .run-header {
      display: flex;
      align-items: baseline;
      gap: var(--space-3);
      flex-wrap: wrap;
      margin-bottom: 0;
    }
    h1 {
      margin: 0;
      color: var(--text-primary);
      font-family: var(--monospace-font);
      font-size: var(--font-size-xl);
      overflow-wrap: anywhere;
    }
    h3 {
      margin: 0 0 0.5rem 0;
      font-size: 0.95rem;
      color: var(--text-primary);
    }
    .state-badge {
      padding: 0.2rem 0.5rem;
      border-radius: 4px;
      font-size: 0.75rem;
      font-weight: 600;
      text-transform: uppercase;
      background: var(--surface);
      color: var(--text-muted);
    }
    .state-badge.state-running {
      background: var(--info-bg, #dbeafe);
      color: var(--info, #0284c7);
    }
    .state-badge.state-waiting,
    .state-badge.state-blocked {
      background: var(--warning-bg, #fef3c7);
      color: var(--warning, #d97706);
    }
    .state-badge.state-failed {
      background: var(--danger-bg, #fee2e2);
      color: var(--danger, #dc2626);
    }
    .state-badge.state-completed,
    .state-badge.state-succeeded {
      background: var(--success-bg, #dcfce7);
      color: var(--success, #16a34a);
    }
    .next-action-panel {
      border: 2px solid var(--accent);
      background: color-mix(in srgb, var(--accent) 10%, var(--surface));
      border-radius: var(--radius-lg);
      padding: var(--space-4);
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
    }
    .next-action-panel.next-reset {
      border-color: var(--warning, #d97706);
      background: var(--warning-bg, #fffbeb);
    }
    .next-action-panel.next-respond {
      border-color: var(--warning, #d97706);
      background: var(--warning-bg, #fffbeb);
    }
    .next-action-panel.disabled {
      border-color: var(--border);
      background: var(--surface);
    }
    .next-action-panel h3 {
      margin: 0;
      color: var(--accent-active);
      font-size: var(--font-size-xs);
      letter-spacing: var(--letter-label);
      text-transform: uppercase;
    }
    .next-action-panel.next-reset h3,
    .next-action-panel.next-respond h3 {
      color: var(--warning, #d97706);
    }
    .action-label {
      margin: 0;
      font-weight: 600;
      color: var(--text-primary);
    }
    .action-text,
    .hint {
      margin: 0;
      color: var(--text-primary);
      font-size: 0.9rem;
    }
    .disabled-reason,
    .control-hint {
      margin: 0;
      color: var(--text-muted);
      font-size: 0.8rem;
    }
    .next-action-controls {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
      margin-top: 0.25rem;
    }
    .notice {
      color: var(--text-muted);
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 0.6rem 0.75rem;
    }
    .actions {
      display: flex;
      align-items: center;
      gap: var(--space-2);
      flex-wrap: wrap;
    }
    .secondary-actions {
      padding-top: var(--space-1);
    }
    .confirm-row {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      font-size: 0.85rem;
      color: var(--text-muted);
    }
    .stages-section,
    .timeline-section,
    .pending-actions {
      border-top: 1px solid var(--border);
      padding-top: 1rem;
    }
    .stages-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
      gap: 0.75rem;
    }
    .stage-card {
      padding: 0.75rem;
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
    }
    .stage-status-queued,
    .stage-status-pending {
      border-left: 4px solid var(--text-muted);
    }
    .stage-status-running {
      border-left: 4px solid var(--info, #0284c7);
      background: var(--info-bg, #dbeafe);
    }
    .stage-status-waiting,
    .stage-status-blocked {
      border-left: 4px solid var(--warning, #d97706);
      background: var(--warning-bg, #fffbeb);
    }
    .stage-status-succeeded,
    .stage-status-completed {
      border-left: 4px solid var(--success, #16a34a);
      background: var(--success-bg, #dcfce7);
    }
    .stage-status-failed {
      border-left: 4px solid var(--danger, #dc2626);
      background: var(--danger-bg, #fee2e2);
    }
    .stage-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 0.5rem;
    }
    .stage-id {
      font-family: var(--monospace-font);
      font-size: 0.8rem;
      font-weight: 600;
    }
    .stage-status {
      font-size: 0.7rem;
      text-transform: uppercase;
      font-weight: 600;
    }
    .stage-kind,
    .stage-attempt,
    .stage-todos,
    .stage-evidence,
    .stage-request,
    .stage-summary,
    .stage-next,
    .stage-log,
    .plan-path {
      margin: 0;
      font-size: 0.75rem;
      color: var(--text-muted);
    }
    .stage-next {
      color: var(--text-primary);
      font-weight: 600;
    }
    .path-label {
      display: block;
      font-weight: 600;
      color: var(--text-primary);
    }
    .plan-path.immutable .path-label {
      color: var(--info, #0284c7);
    }
    .plan-path.control .path-label {
      color: var(--warning, #d97706);
    }
    .timeline {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      position: relative;
      padding-left: 1.5rem;
    }
    .timeline::before {
      content: '';
      position: absolute;
      left: 0.45rem;
      top: 0;
      bottom: 0;
      width: 1px;
      background: var(--border);
    }
    .timeline-event {
      display: flex;
      gap: 1rem;
      position: relative;
      flex-wrap: wrap;
    }
    .timeline-event::before {
      content: '';
      position: absolute;
      left: -1rem;
      top: 0.25rem;
      width: 0.7rem;
      height: 0.7rem;
      border-radius: 50%;
      background: var(--border);
      border: 2px solid var(--page-bg, white);
    }
    .timeline-event.event-type-stage-start::before,
    .timeline-event.event-type-run-created::before {
      background: var(--info, #0284c7);
    }
    .timeline-event.event-type-stage-end::before {
      background: var(--success, #16a34a);
    }
    .timeline-event.event-type-action-request::before {
      background: var(--warning, #d97706);
    }
    .timeline-event.event-type-action-response::before {
      background: var(--success, #16a34a);
    }
    .timeline-event.event-type-verification::before {
      background: var(--danger, #dc2626);
    }
    .timeline-event.event-type-rework::before {
      background: var(--warning, #d97706);
    }
    .event-time {
      font-family: var(--monospace-font);
      font-size: 0.75rem;
      color: var(--text-muted);
      min-width: 7rem;
    }
    .event-content {
      flex: 1;
      min-width: 0;
    }
    .event-message {
      margin: 0;
      font-size: 0.85rem;
      color: var(--text-primary);
    }
    .event-stage {
      margin: 0.2rem 0 0 0;
      font-size: 0.75rem;
      color: var(--text-muted);
    }
    .pending-actions h3 {
      margin: 0 0 0.4rem;
      font-size: 0.9rem;
    }
    .muted {
      color: var(--text-muted);
    }
    .action-card {
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      background: var(--surface);
      padding: var(--space-3);
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
      margin-bottom: var(--space-2);
    }
    .action-card.action-primary {
      border-width: 2px;
      border-color: var(--accent);
      box-shadow: 0 0 0 1px color-mix(in srgb, var(--accent) 30%, transparent);
    }
    .action-card.action-disabled {
      opacity: 0.85;
    }
    .question {
      margin: 0;
      font-size: 0.85rem;
    }
    .action-meta {
      margin: 0;
      font-size: 0.75rem;
      color: var(--text-muted);
    }
    .action-status {
      margin-left: 0.35rem;
      font-weight: 600;
      text-transform: uppercase;
    }
    .persisted-decision {
      margin: 0;
      font-size: 0.8rem;
      color: var(--success, #16a34a);
    }
    .respond-row {
      display: flex;
      gap: 0.4rem;
      flex-wrap: wrap;
    }
  `,
})
export class WorkflowRunDetailPageComponent implements OnInit {
  readonly facade = inject(WorkflowsFacade);
  readonly capabilities = inject(CapabilitiesService);
  private readonly route = inject(ActivatedRoute);
  private readonly destroyRef = inject(DestroyRef);

  readonly decisions = DECISIONS;
  readonly confirmingCancel = signal(false);
  readonly pendingDecisions = signal<ReadonlyMap<string, ActionDecision>>(new Map());
  readonly messages: Record<string, string> = {};

  private currentRunId = '';

  readonly stages = computed((): readonly StageMapEntry[] => {
    const status = this.facade.runStatus();
    return status?.detail?.stageMap ?? this.fallbackStages(status);
  });

  readonly timeline = computed((): readonly RunTimelineEvent[] => {
    const status = this.facade.runStatus();
    return status?.detail?.timeline ?? [];
  });

  readonly operatorNext = computed((): OperatorNextAction | null => {
    return this.facade.runStatus()?.detail?.operatorNext ?? null;
  });

  readonly actions = computed((): readonly RunActionDetail[] => {
    return this.facade.runStatus()?.detail?.actions ?? [];
  });

  messageNeeded(): ReadonlySet<string> {
    return new Set(this.pendingDecisions().keys());
  }

  runId(): string {
    return this.currentRunId;
  }

  runState(): string | null {
    const run = this.facade.runStatus()?.run as { state?: unknown } | undefined;
    return typeof run?.state === 'string' ? run.state : null;
  }

  workflowId(): string | null {
    const run = this.facade.runStatus()?.run as { workflowId?: unknown } | undefined;
    return typeof run?.workflowId === 'string' ? run.workflowId : null;
  }

  /** The originating task text, carried on run.json since the run was created. */
  task(): string | null {
    const run = this.facade.runStatus()?.run as { task?: unknown } | undefined;
    return typeof run?.task === 'string' && run.task.length > 0 ? run.task : null;
  }

  isTerminal(): boolean {
    const state = this.runState();
    return state ? ['succeeded', 'failed', 'cancelled'].includes(state) : false;
  }

  canResume(): boolean {
    const next = this.operatorNext();
    if (next) {
      if (next.kind === 'resume') {
        return next.enabled;
      }
      if (next.kind === 'respond' || next.kind === 'reset') {
        return false;
      }
      if (next.disabledReason && (next.kind === 'none' || this.isTerminal())) {
        return false;
      }
    }
    const state = this.runState();
    return state ? ['waiting', 'blocked', 'paused', 'failed', 'stale'].includes(state) : false;
  }

  resumeDisabledReason(): string | null {
    if (this.canResume()) {
      return null;
    }
    const next = this.operatorNext();
    if (next?.disabledReason && (next.kind === 'resume' || next.kind === 'respond' || next.kind === 'reset')) {
      return next.disabledReason;
    }
    if (next?.kind === 'respond') {
      return 'Answer the outstanding request before resume';
    }
    if (next?.kind === 'reset') {
      return 'Reset the changes target before resume';
    }
    if (this.isTerminal()) {
      return `Run is ${this.runState()}; resume is closed`;
    }
    return null;
  }

  canShowReset(): boolean {
    return this.operatorNext()?.kind === 'reset';
  }

  isPrimaryActionCard(action: RunActionDetail): boolean {
    const next = this.operatorNext();
    return !!next && next.kind === 'respond' && next.requestId === action.requestId && action.enabled;
  }

  decisionButtonClass(action: RunActionDetail, index: number): string {
    if (this.isPrimaryActionCard(action) && index === 0) {
      return 'btn btn-primary';
    }
    return 'btn btn-ghost';
  }

  planBasename(path: string | null): string {
    return basename(path) ?? path ?? '';
  }

  decisionsFor(action: RunActionDetail): readonly string[] {
    return action.choices.length > 0 ? action.choices : this.decisions;
  }

  formatTime(timestamp: string): string {
    try {
      const date = new Date(timestamp);
      return date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    } catch {
      return timestamp;
    }
  }

  ngOnInit(): void {
    this.capabilities.load();
    this.route.paramMap.subscribe((params) => {
      const runId = params.get('runId');
      if (runId) {
        this.currentRunId = runId;
        void this.facade.loadRunStatus(runId);
      }
    });
    this.destroyRef.onDestroy(() => this.facade.stopRunStatusPolling());
  }

  async doCancel(): Promise<void> {
    this.confirmingCancel.set(false);
    await this.facade.cancelRun(this.currentRunId);
  }

  async doResume(): Promise<void> {
    await this.facade.resumeRun(this.currentRunId);
  }

  async doReset(stageId: string | null): Promise<void> {
    if (!stageId) {
      return;
    }
    await this.facade.resetRun(this.currentRunId, { stage: stageId });
  }

  respond(requestId: string, decision: ActionDecision | string): void {
    const typed = decision as ActionDecision;
    if (MESSAGE_DECISIONS.has(typed)) {
      const next = new Map(this.pendingDecisions());
      next.set(requestId, typed);
      this.pendingDecisions.set(next);
      return;
    }
    void this.sendResponse(requestId, typed);
  }

  async sendResponseWithMessage(requestId: string): Promise<void> {
    const message = this.messages[requestId]?.trim();
    const decision = this.pendingDecisions().get(requestId);
    if (!message || !decision) {
      return;
    }
    await this.sendResponse(requestId, decision, message);
  }

  private async sendResponse(requestId: string, decision: ActionDecision, message?: string): Promise<void> {
    const ok = await this.facade.respondAction(this.currentRunId, { requestId, decision, message });
    if (ok) {
      const next = new Map(this.pendingDecisions());
      next.delete(requestId);
      this.pendingDecisions.set(next);
      delete this.messages[requestId];
      await this.facade.loadRunStatus(this.currentRunId);
    }
  }

  private fallbackStages(status: RunStatus | null): StageMapEntry[] {
    if (!status?.stages || !Array.isArray(status.stages)) {
      return [];
    }
    return status.stages.map((stage, idx) => {
      const rec = stage as Record<string, unknown>;
      const id = typeof rec['id'] === 'string' ? rec['id'] : `stage-${idx}`;
      const state = typeof rec['state'] === 'string' ? rec['state'] : typeof rec['status'] === 'string' ? (rec['status'] as string) : 'queued';
      const attempt = typeof rec['attempt'] === 'number' ? rec['attempt'] : 0;
      return {
        id,
        state,
        attempt,
        stageKind: typeof rec['stageKind'] === 'string' ? rec['stageKind'] : 'executable',
        todoProgress: null,
        requiredEvidence: [],
        producedEvidence: [],
        actionRequestId: typeof rec['requestId'] === 'string' ? rec['requestId'] : null,
        requestState: typeof rec['requestState'] === 'string' ? rec['requestState'] : null,
        nextPermittedAction: null,
        sourcePlanPath: typeof rec['sourcePlanPath'] === 'string' ? rec['sourcePlanPath'] : null,
        controlPlanPath: typeof rec['controlPlanPath'] === 'string' ? rec['controlPlanPath'] : null,
        planSourceKind: typeof rec['planSourceKind'] === 'string' ? rec['planSourceKind'] : null,
        reasonCode: typeof rec['reasonCode'] === 'string' ? rec['reasonCode'] : null,
        summary: typeof rec['error'] === 'string' ? rec['error'] : null,
        reworkRound: attempt > 1 ? attempt : 0,
        logScope: null,
      };
    });
  }
}
