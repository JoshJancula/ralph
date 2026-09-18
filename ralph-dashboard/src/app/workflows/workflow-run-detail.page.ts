import { Component, DestroyRef, OnInit, computed, effect, inject, signal } from '@angular/core';
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

      <div class="run-header hub-panel-card">
        <div class="run-header-main">
          <p class="eyebrow">Workflow run</p>
          <div class="run-title-row">
            <h1 class="page-title" data-testid="run-detail-title">{{ runId() }}</h1>
            @if (runState(); as state) {
              <span class="status-badge state-badge" [class]="'state-' + state" data-testid="run-state">{{ stageStatusLabel(state) }}</span>
            }
          </div>
          @if (workflowId(); as wfId) {
            <a class="run-workflow-link" [routerLink]="['/workflows', wfId]">{{ wfId }}</a>
          }
        </div>
      </div>

      @if (task(); as taskText) {
        <section class="user-prompt hub-panel-card" data-testid="run-detail-user-prompt">
          <div class="section-head">
            <h2 class="section-legend">User prompt</h2>
            <p class="section-hint">Task or instructions supplied when this run was started (from --task or a supplied plan).</p>
          </div>
          <div class="prompt-body" data-testid="run-detail-task">{{ taskText }}</div>
        </section>
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
          <section class="stages-section hub-panel-card" data-testid="stages-section">
            <div class="stage-map-head">
              <div class="section-head">
                <h3 class="section-legend">Stage map</h3>
                <p class="section-hint">Stages that ran or are active. Skipped rework clones are hidden by default.</p>
              </div>
              @if (skippedStageCount() > 0) {
                <button
                  type="button"
                  class="btn btn-ghost"
                  data-testid="toggle-skipped-stages"
                  (click)="showSkippedStages.set(!showSkippedStages())"
                >
                  {{ showSkippedStages() ? 'Hide' : 'Show' }} {{ skippedStageCount() }} skipped
                </button>
              }
            </div>
            <div class="stage-lane" role="list">
              @for (stage of displayStages(); track stage.id) {
                <article
                  class="stage-chip hub-choice-card"
                  role="listitem"
                  [class.selected]="selectedStageId() === stage.id"
                  [ngClass]="'stage-status-' + stage.state"
                  [attr.data-testid]="'stage-' + stage.id"
                  (click)="selectedStageId.set(stage.id)"
                >
                  <div class="chip-head">
                    <span class="status-badge chip-state" [class]="'state-' + stage.state">{{ stageStatusLabel(stage.state) }}</span>
                    @if (stage.reworkRound > 1) {
                      <span class="chip-rework">R{{ stage.reworkRound }}</span>
                    }
                  </div>
                  <h4 class="chip-title">{{ stage.id }}</h4>
                  <p class="chip-meta">
                    {{ stage.stageKind }}
                  </p>
                  @if (stage.attempt > 0) {
                    <p class="chip-meta" data-testid="stage-attempt">
                      Attempt {{ stage.attempt }}
                      @if (stage.reworkRound > 1) {
                        <span> (rework round {{ stage.reworkRound }})</span>
                      }
                    </p>
                  }
                  @if (stage.todoProgress; as todos) {
                    <p class="chip-meta" data-testid="stage-todo-progress">
                      TODOs {{ todos.completed }}/{{ todos.total }}
                      @if (todos.currentTodoId) {
                        <span> · {{ todos.currentTodoId }}</span>
                      }
                    </p>
                  }
                  @if (stage.summary) {
                    <p class="chip-summary stage-summary">{{ stage.summary }}</p>
                  }
                  @if (stage.nextPermittedAction) {
                    <p class="chip-next" data-testid="stage-next-action">{{ stage.nextPermittedAction }}</p>
                  }
                  @if (stage.attempt > 0) {
                    <a
                      class="chip-link"
                      [routerLink]="['/workflows/runs', runId(), 'stages', stage.id, 'logs']"
                      [queryParams]="{ attempt: stage.attempt || 1 }"
                      data-testid="stage-log-scope"
                      (click)="$event.stopPropagation()"
                    >
                      View logs
                    </a>
                  }
                  @if (hasStageDetails(stage)) {
                    <details class="stage-more" (click)="$event.stopPropagation()">
                      <summary>Paths and evidence</summary>
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
                          Required: {{ evidenceSummary(stage.requiredEvidence) }}
                        </p>
                      }
                      @if (stage.producedEvidence.length > 0) {
                        <p class="stage-evidence" data-testid="stage-produced-evidence">
                          Evidence: {{ evidenceSummary(stage.producedEvidence) }}
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
                    </details>
                  }
                </article>
              }
            </div>
          </section>
        }

        @if (timeline().length > 0) {
          <section class="timeline-section hub-panel-card" data-testid="timeline-section">
            <div class="section-head">
              <h3 class="section-legend">Timeline</h3>
              <p class="section-hint">Supervisor-recorded milestones in chronological order.</p>
            </div>
            <ol class="timeline">
              @for (event of timeline(); track event.id; let i = $index) {
                <li class="timeline-item" [class]="'event-type-' + event.type" [attr.data-testid]="'event-' + event.type">
                  <span class="timeline-marker" aria-hidden="true"></span>
                  <div class="timeline-body">
                    <div class="timeline-meta">
                      @if (showTimelineTime(event, i)) {
                        <time class="event-time">{{ formatTime(event.timestamp) }}</time>
                      }
                      @if (event.stageId) {
                        <span class="event-stage-id">{{ event.stageId }}</span>
                      }
                    </div>
                    <p class="event-message">{{ event.message }}</p>
                  </div>
                </li>
              }
            </ol>
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
      width: min(100%, 72rem);
      flex: 1;
      min-height: 0;
      overflow-x: hidden;
      overflow-y: auto;
      padding-bottom: calc(var(--space-6) + var(--fab-clearance));
    }
    .run-header {
      padding: 1rem 1.1rem;
      background: linear-gradient(
        135deg,
        color-mix(in srgb, var(--ion-color-step-50, #0d1117) 88%, var(--accent) 12%),
        var(--ion-color-step-50, #0d1117)
      );
    }
    .run-header-main {
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
      min-width: 0;
    }
    .eyebrow {
      margin: 0;
      color: var(--accent-active);
      font-size: var(--font-size-xs);
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    .run-title-row {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: var(--space-2);
    }
    .page-title {
      margin: 0;
      font-family: var(--monospace-font);
      font-size: clamp(1.1rem, 2.4vw, var(--font-size-xl));
      overflow-wrap: anywhere;
    }
    .run-workflow-link {
      color: var(--text-link);
      font-size: var(--font-size-sm);
      font-weight: 600;
      text-decoration: none;
    }
    .run-workflow-link:hover {
      text-decoration: underline;
    }
    .user-prompt .prompt-body {
      margin: 0;
      padding: var(--space-3);
      border: 1px solid var(--panel-border);
      border-radius: var(--radius-md);
      background: var(--code-bg, var(--surface-secondary));
      color: var(--text-primary);
      font-size: var(--font-size-sm);
      line-height: var(--line-height-body);
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }
    h3 {
      margin: 0;
    }
    .state-badge {
      text-transform: uppercase;
    }
    .state-badge.state-running {
      color: var(--info);
      border-color: color-mix(in srgb, var(--info) 45%, var(--panel-border));
      background: color-mix(in srgb, var(--info) 12%, transparent);
    }
    .state-badge.state-waiting,
    .state-badge.state-blocked {
      color: var(--warning);
      border-color: color-mix(in srgb, var(--warning) 45%, var(--panel-border));
      background: color-mix(in srgb, var(--warning) 12%, transparent);
    }
    .state-badge.state-failed {
      color: var(--danger);
      border-color: color-mix(in srgb, var(--danger) 45%, var(--panel-border));
      background: color-mix(in srgb, var(--danger) 12%, transparent);
    }
    .state-badge.state-completed,
    .state-badge.state-succeeded {
      color: var(--success-text, var(--success));
      border-color: color-mix(in srgb, var(--success) 45%, var(--panel-border));
      background: var(--success-bg);
    }
    .next-action-panel {
      border: 1px solid color-mix(in srgb, var(--accent) 55%, var(--panel-border));
      background: color-mix(in srgb, var(--accent) 8%, var(--panel-bg));
    }
    .next-action-panel.next-reset,
    .next-action-panel.next-respond {
      border-color: color-mix(in srgb, var(--warning) 55%, var(--panel-border));
      background: color-mix(in srgb, var(--warning) 10%, var(--panel-bg));
    }
    .next-action-panel.disabled {
      border-color: var(--panel-border);
      background: var(--panel-bg);
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
      color: var(--warning);
    }
    .action-label {
      margin: 0;
      font-weight: 600;
      color: var(--text-primary);
    }
    .action-text,
    .hint {
      margin: 0;
      color: var(--text-secondary);
      font-size: var(--font-size-sm);
    }
    .disabled-reason,
    .control-hint {
      margin: 0;
      color: var(--text-muted);
      font-size: var(--font-size-xs);
    }
    .next-action-controls {
      display: flex;
      gap: var(--space-2);
      flex-wrap: wrap;
      margin-top: var(--space-1);
    }
    .notice {
      margin: 0;
      color: var(--text-muted);
      background: var(--panel-bg);
      border: 1px solid var(--panel-border);
      border-radius: var(--radius-lg);
      padding: 0.8rem 0.9rem;
    }
    .actions {
      display: flex;
      align-items: center;
      gap: var(--space-2);
      flex-wrap: wrap;
    }
    .confirm-row {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      font-size: var(--font-size-sm);
      color: var(--text-muted);
    }
    .pending-actions {
      padding-top: 0;
      border-top: 0;
    }
    .stage-map-head {
      display: flex;
      flex-wrap: wrap;
      align-items: flex-start;
      justify-content: space-between;
      gap: var(--space-3);
      margin-bottom: var(--space-2);
    }
    .stage-lane {
      display: flex;
      gap: var(--space-3);
      overflow-x: auto;
      padding-bottom: var(--space-1);
      scroll-snap-type: x proximity;
      -webkit-overflow-scrolling: touch;
    }
    .stage-chip {
      flex: 0 0 min(15rem, 78vw);
      scroll-snap-align: start;
      align-items: stretch;
      gap: 0.35rem;
      padding: 0.85rem 0.95rem;
      cursor: pointer;
    }
    .stage-chip.selected {
      border-color: var(--accent);
      box-shadow: 0 0 0 1px color-mix(in srgb, var(--accent) 45%, transparent);
    }
    .stage-chip.stage-status-failed.selected {
      border-color: var(--danger);
      box-shadow: 0 0 0 1px color-mix(in srgb, var(--danger) 45%, transparent);
    }
    .chip-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: var(--space-2);
    }
    .chip-state {
      font-size: 0.65rem;
    }
    .chip-rework {
      font-size: var(--font-size-xs);
      color: var(--text-muted);
      font-weight: 700;
    }
    .chip-title {
      margin: 0.15rem 0 0;
      font-family: var(--monospace-font);
      font-size: var(--font-size-md);
      font-weight: 650;
      color: var(--text-primary);
      overflow-wrap: anywhere;
    }
    .chip-meta,
    .chip-summary,
    .chip-next {
      margin: 0;
      font-size: var(--font-size-xs);
      color: var(--text-muted);
      line-height: 1.35;
    }
    .chip-next {
      color: var(--text-secondary);
      font-weight: 600;
    }
    .chip-link {
      margin-top: 0.25rem;
      color: var(--text-link);
      font-size: var(--font-size-xs);
      font-weight: 600;
      text-decoration: none;
    }
    .chip-link:hover {
      text-decoration: underline;
    }
    .stage-more {
      margin-top: 0.35rem;
      font-size: var(--font-size-xs);
      color: var(--text-muted);
    }
    .stage-more summary {
      cursor: pointer;
      color: var(--text-link);
      font-weight: 600;
    }
    .stage-evidence,
    .stage-request,
    .plan-path {
      margin: 0.35rem 0 0;
      font-size: var(--font-size-xs);
      color: var(--text-muted);
    }
    .path-label {
      display: block;
      font-weight: 600;
      color: var(--text-secondary);
    }
    .timeline {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: 0;
      position: relative;
      padding-left: 1.35rem;
    }
    .timeline::before {
      content: '';
      position: absolute;
      left: 0.42rem;
      top: 0.35rem;
      bottom: 0.35rem;
      width: 2px;
      background: var(--panel-border);
      border-radius: 1px;
    }
    .timeline-item {
      position: relative;
      display: flex;
      gap: var(--space-3);
      padding: 0.55rem 0;
    }
    .timeline-item + .timeline-item {
      border-top: 1px solid color-mix(in srgb, var(--panel-border) 65%, transparent);
    }
    .timeline-marker {
      position: absolute;
      left: -1.35rem;
      top: 0.85rem;
      width: 0.55rem;
      height: 0.55rem;
      border-radius: 50%;
      background: var(--panel-border);
      box-shadow: 0 0 0 2px var(--panel-bg);
    }
    .timeline-item.event-type-run-created .timeline-marker,
    .timeline-item.event-type-stage-start .timeline-marker {
      background: var(--info);
    }
    .timeline-item.event-type-stage-end .timeline-marker {
      background: var(--success);
    }
    .timeline-item.event-type-action-request .timeline-marker,
    .timeline-item.event-type-rework .timeline-marker {
      background: var(--warning);
    }
    .timeline-item.event-type-action-response .timeline-marker {
      background: var(--success);
    }
    .timeline-item.event-type-verification .timeline-marker {
      background: var(--danger);
    }
    .timeline-body {
      flex: 1;
      min-width: 0;
    }
    .timeline-meta {
      display: flex;
      flex-wrap: wrap;
      align-items: baseline;
      gap: 0.35rem 0.65rem;
      margin-bottom: 0.15rem;
    }
    .event-time {
      font-family: var(--monospace-font);
      font-size: var(--font-size-xs);
      color: var(--text-muted);
    }
    .event-stage-id {
      font-family: var(--monospace-font);
      font-size: var(--font-size-xs);
      font-weight: 600;
      color: var(--text-secondary);
    }
    .event-message {
      margin: 0;
      font-size: var(--font-size-sm);
      color: var(--text-primary);
      line-height: 1.4;
    }
    .pending-actions h3 {
      margin: 0 0 0.4rem;
      font-size: var(--font-size-xs);
      font-weight: 700;
      letter-spacing: var(--letter-label);
      text-transform: uppercase;
    }
    .muted {
      color: var(--text-muted);
    }
    .action-card {
      border: 1px solid var(--panel-border);
      border-radius: var(--radius-lg);
      background: var(--panel-bg);
      padding: var(--space-3);
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
      margin-bottom: var(--space-2);
    }
    .action-card.action-primary {
      border-color: var(--accent);
      box-shadow: 0 0 0 1px color-mix(in srgb, var(--accent) 30%, transparent);
    }
    .question {
      margin: 0;
      font-size: var(--font-size-sm);
    }
    .action-meta {
      margin: 0;
      font-size: var(--font-size-xs);
      color: var(--text-muted);
    }
    .action-status {
      margin-left: 0.35rem;
      font-weight: 600;
      text-transform: uppercase;
    }
    .persisted-decision {
      margin: 0;
      font-size: var(--font-size-sm);
      color: var(--success-text, var(--success));
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
  readonly showSkippedStages = signal(false);
  readonly selectedStageId = signal<string | null>(null);

  private currentRunId = '';

  readonly skippedStageCount = computed(() => this.stages().filter((stage) => stage.state === 'skipped').length);

  readonly displayStages = computed(() => {
    const all = this.stages();
    return this.showSkippedStages() ? all : all.filter((stage) => stage.state !== 'skipped');
  });

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

  evidenceSummary(paths: readonly string[]): string {
    return paths.map((path) => this.shortEvidence(path)).join(', ');
  }

  shortEvidence(path: string): string {
    return basename(path) ?? path;
  }

  hasStageDetails(stage: StageMapEntry): boolean {
    return (
      !!stage.sourcePlanPath
      || !!stage.controlPlanPath
      || stage.requiredEvidence.length > 0
      || stage.producedEvidence.length > 0
      || !!stage.actionRequestId
    );
  }

  stageStatusLabel(state: string): string {
    switch (state) {
      case 'succeeded':
      case 'completed':
        return 'Completed';
      case 'failed':
        return 'Failed';
      case 'running':
        return 'Running';
      case 'waiting':
        return 'Waiting';
      case 'blocked':
        return 'Blocked';
      case 'skipped':
        return 'Skipped';
      case 'cancelled':
        return 'Cancelled';
      case 'queued':
      case 'pending':
        return 'Pending';
      default:
        return state;
    }
  }

  showTimelineTime(event: RunTimelineEvent, index: number): boolean {
    if (index === 0) {
      return true;
    }
    const prev = this.timeline()[index - 1];
    return !prev || prev.timestamp !== event.timestamp;
  }

  formatTime(timestamp: string): string {
    try {
      const date = new Date(timestamp);
      return date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    } catch {
      return timestamp;
    }
  }

  decisionsFor(action: RunActionDetail): readonly string[] {
    return action.choices.length > 0 ? action.choices : this.decisions;
  }

  constructor() {
    effect(() => {
      const stages = this.displayStages();
      const current = this.selectedStageId();
      if (stages.length === 0) {
        return;
      }
      if (current && stages.some((stage) => stage.id === current)) {
        return;
      }
      const pick =
        stages.find((stage) => stage.state === 'failed')
        ?? stages.find((stage) => stage.state === 'running' || stage.state === 'waiting')
        ?? stages[stages.length - 1];
      this.selectedStageId.set(pick?.id ?? stages[0]!.id);
    });
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
