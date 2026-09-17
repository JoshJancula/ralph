import { Component, OnInit, computed, effect, inject, signal } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { shouldShowRouteSkeleton } from '../utils/request-lifecycle';
import { FormsModule } from '@angular/forms';
import { RouteLoadStateComponent } from '../components/route-load-state/route-load-state.component';
import { ErrorDialogService } from '../services/error-dialog.service';
import { WorkspaceSelectorService } from '../services/workspace-selector.service';
import { WorkflowsApi } from '../workflows/workflows-api.service';
import type { WorkflowListItem } from '../workflows/workflow.types';
import { TasksInventoryStore } from '../services/tasks-inventory.store';
import { TasksSchedulesService, type DashboardAttempt, type DashboardTask } from '../services/tasks-schedules.service';
import { AssistantStore } from '../assistant/assistant.store';
import { ModelSelectComponent } from '../workflows/components/model-select.component';

const RUNTIME_OPTIONS = ['cursor', 'claude', 'codex', 'opencode', 'antigravity'] as const;

type Draft = {
  title: string;
  description: string;
  acceptanceCriteria: string;
  workflowId: string;
  runtime: string;
  model: string;
  status: string;
  scope: 'project' | 'global';
  targetMode: 'registered' | 'new-project' | 'global';
  targetWorkspaceRoot: string;
  projectPath: string;
};

const blank = (): Draft => ({
  title: '',
  description: '',
  acceptanceCriteria: '',
  workflowId: '',
  runtime: '',
  model: '',
  status: 'backlog',
  scope: 'project',
  targetMode: 'registered',
  targetWorkspaceRoot: '',
  projectPath: '',
});

@Component({
  selector: 'ralph-tasks-page',
  standalone: true,
  imports: [FormsModule, RouterLink, RouteLoadStateComponent, ModelSelectComponent],
  template: `
    <main class="page hub-page" data-testid="tasks-page">
      <header class="page-header">
        <div>
          <p class="eyebrow">Work queue</p>
          <h1 class="page-title">{{ pageTitle() }}</h1>
          <p class="page-lede">{{ pageLede() }}</p>
        </div>
        <div class="header-actions">
          @if (taskView() === 'active-board') {
            <button type="button" class="btn btn-ghost" (click)="showStatuses.set(true)">Manage statuses</button>
          }
          <button type="button" class="btn btn-primary" (click)="create()">New task</button>
        </div>
      </header>

      <div class="hub-toolbar">
        @if (taskView() === 'active-board') {
          <div class="switch" role="group" aria-label="Active task view mode">
            <button type="button" class="switch-btn" [class.active]="view() === 'board'" (click)="view.set('board')">
              Board
            </button>
            <button type="button" class="switch-btn" [class.active]="view() === 'list'" (click)="view.set('list')">
              List
            </button>
          </div>
        }
        <span class="toolbar-meta">{{ visibleTasks().length }} {{ visibleTasks().length === 1 ? 'task' : 'tasks' }}</span>
      </div>

      <ralph-route-load-state
        [loading]="showLoadingSkeleton()"
        [errorDetail]="error()"
        [columns]="3"
        [rowCount]="5"
        (retry)="load()"
      />

      @if (!showLoadingSkeleton() && !error()) {
        @if (!visibleTasks().length) {
          <section class="empty-state" data-testid="tasks-empty">
            <p class="empty-title">{{ emptyTitle() }}</p>
            <p class="empty-hint">{{ emptyHint() }}</p>
            <div class="empty-actions">
              <button type="button" class="btn btn-primary" (click)="create()">Create first task</button>
            </div>
          </section>
        } @else if (taskView() === 'active-board' && view() === 'board') {
          <section class="board" aria-label="Task board">
            @for (status of boardStatuses(); track status) {
              <section class="column">
                <header class="column-header">
                  <div class="column-title-wrap">
                    <span class="column-title">{{ label(status) }}</span>
                    <span class="column-count">{{ items(status).length }}</span>
                  </div>
                </header>
                <div
                  class="column-body"
                  [class.drop-target]="dragTargetStatus() === status"
                  (dragover)="onDragOver($event, status)"
                  (dragleave)="onDragLeave(status)"
                  (drop)="onDrop($event, status)"
                >
                  @for (task of items(status); track task.id) {
                    <button
                      type="button"
                      class="task-card"
                      [class.dragging]="draggingTask()?.id === task.id"
                      draggable="true"
                      (dragstart)="onDragStart($event, task)"
                      (dragend)="onDragEnd()"
                      (click)="edit(task)"
                      [attr.aria-label]="'Edit task: ' + task.title"
                    >
                      <div class="card-title-row">
                        <span class="card-title">{{ task.title }}</span>
                      </div>
                      <p class="card-desc">{{ task.description || 'No description yet' }}</p>
                      <div class="card-meta">
                        <span class="meta-tag">{{ !task.workflowId || task.workflowId === 'auto' ? 'Auto' : task.workflowId }}</span>
                        <span class="meta-tag target-tag">{{ target(task) }}</span>
                      </div>
                      @if (task.autoRecommendation && task.status === 'blocked') {
                        <div class="card-alert alert-recommendation">
                          <span class="alert-label">Recommendation:</span> {{ task.autoRecommendation }}
                        </div>
                      }
                      @if (lastAttempt(task); as attempt) {
                        <div class="card-alert alert-attempt" [class.failed]="attempt.outcome === 'blocked' || attempt.status === 'failed'">
                          <span class="alert-label">Last run:</span> {{ attempt.outcome || attempt.status }}
                          @if (attempt.summary || attempt.error) {
                            <span class="alert-detail"> — {{ attempt.summary || attempt.error }}</span>
                          }
                        </div>
                      }
                    </button>
                  }
                  @if (!items(status).length) {
                    <div class="column-empty">No tasks here</div>
                  }
                </div>
              </section>
            }
          </section>
        } @else {
          <section class="list-container data-table" aria-label="Task list">
            <div class="list-head data-table-header">
              <span class="col-main">Task</span>
              <span class="col-status">Status</span>
              <span class="col-workflow">Workflow</span>
              <span class="col-target">Target</span>
              <span class="col-actions">Actions</span>
            </div>
            @for (task of visibleTasks(); track task.id) {
              <article
                class="list-row data-table-row"
                role="button"
                tabindex="0"
                [attr.aria-label]="'Edit task: ' + task.title"
                (click)="edit(task)"
                (keydown.enter)="edit(task)"
                (keydown.space)="$event.preventDefault(); edit(task)"
              >
                <div class="col-main">
                  <b class="row-title">{{ task.title }}</b>
                  <p class="row-desc">{{ task.description || 'No description yet' }}</p>
                </div>
                <div class="col-status">
                  <select
                    class="status-select"
                    [ngModel]="task.status"
                    (ngModelChange)="move(task, $event)"
                    (click)="$event.stopPropagation()"
                    aria-label="Change status"
                  >
                    @for (status of statuses(); track status) {
                      <option [value]="status">{{ label(status) }}</option>
                    }
                  </select>
                </div>
                <div class="col-workflow">
                  <span class="meta-tag">{{ task.workflowId || 'Unassigned' }}</span>
                </div>
                <div class="col-target">
                  <span class="target-text">{{ target(task) }}</span>
                </div>
                <div class="col-actions">
                  @if (task.status === 'ready' || task.status === 'backlog') {
                    <button type="button" class="btn btn-primary" data-testid="task-run-now" (click)="$event.stopPropagation(); runNow(task)">Run now</button>
                  }
                  <button type="button" class="btn btn-ghost" (click)="$event.stopPropagation(); edit(task)">Edit</button>
                </div>
              </article>
            }
          </section>
        }
      }

      @if (open()) {
        <div class="hub-modal-backdrop" (click)="close()">
          <section
            class="modal-panel task-dialog hub-modal-panel"
            data-testid="task-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="task-dialog-title"
            (click)="$event.stopPropagation()"
          >
            <header class="modal-header">
              <div class="modal-header-main">
                <p class="eyebrow">{{ editingId() ? 'Task detail' : 'New task' }}</p>
                <div class="modal-title-row">
                  <h2 id="task-dialog-title" class="modal-title">{{ editingId() ? 'Edit task' : 'Define the work' }}</h2>
                  @if (editingId()) {
                    <span class="status-pill" [class]="statusClass(model.status)">{{ label(model.status) }}</span>
                  }
                </div>
                @if (editingTask(); as task) {
                  <p class="modal-meta">
                    <span class="meta-tag workflow-tag">{{ model.workflowId || 'Unassigned' }}</span>
                    <span class="meta-sep" aria-hidden="true">·</span>
                    <span>{{ target(task) }}</span>
                    <span class="meta-sep" aria-hidden="true">·</span>
                    <span>Updated {{ formatTaskTime(task.updatedAt) }}</span>
                  </p>
                } @else {
                  <p class="modal-lede">Capture the outcome, how it should run, and where work executes.</p>
                }
              </div>
              <button type="button" class="close-btn" aria-label="Close dialog" (click)="close()">×</button>
            </header>

            @if (editingTask()?.autoRecommendation && editingTask()?.status === 'blocked') {
              <div class="modal-banner banner-recommendation" role="status">
                <span class="banner-label">Recommendation</span>
                <p class="banner-text">{{ editingTask()?.autoRecommendation }}</p>
              </div>
            }

            <form (ngSubmit)="save()" class="modal-form">
              <div class="modal-body">
                <section class="form-section form-section-card">
                  <div class="section-head">
                    <h3 class="section-legend">Outcome</h3>
                    <p class="section-hint">What success looks like for this task.</p>
                  </div>
                  <label class="field-label">
                    <span>Title</span>
                    <input
                      type="text"
                      name="title"
                      class="form-control"
                      [(ngModel)]="model.title"
                      required
                      placeholder="A short, concrete outcome"
                    />
                  </label>
                  <label class="field-label">
                    <div class="label-with-sub">
                      <span>Description</span>
                      <small class="label-aside">Context and constraints</small>
                    </div>
                    <textarea
                      name="description"
                      class="form-control"
                      [(ngModel)]="model.description"
                      rows="3"
                      placeholder="Context, constraints, and desired result"
                    ></textarea>
                  </label>
                  <label class="field-label">
                    <div class="label-with-sub">
                      <span>Acceptance criteria</span>
                      <small class="label-aside">One line per criterion</small>
                    </div>
                    <textarea
                      name="criteria"
                      class="form-control criteria-input"
                      [(ngModel)]="model.acceptanceCriteria"
                      rows="4"
                      placeholder="One verifiable criterion per line"
                    ></textarea>
                  </label>
                </section>

                <section class="form-section form-section-card">
                  <div class="section-head">
                    <h3 class="section-legend">Execution</h3>
                    <p class="section-hint">Workflow, board status, and queue placement.</p>
                  </div>
                  <div class="form-grid">
                    <label class="field-label">
                      <span>Workflow</span>
                      @if (workflowLoading()) {
                        <span class="field-hint">Loading workflows…</span>
                      } @else if (!workflows().length) {
                        <span class="field-hint danger">No workflows available.</span>
                      } @else {
                        <select name="workflow" class="form-control" [(ngModel)]="model.workflowId" required>
                          <option value="" disabled>Select a workflow…</option>
                          @for (w of workflows(); track w.id) {
                            <option [value]="w.id">{{ w.id }} — {{ w.overview }}</option>
                          }
                        </select>
                      }
                    </label>
                    <label class="field-label">
                      <span>Status</span>
                      <select name="status" class="form-control" [(ngModel)]="model.status">
                        @for (status of statuses(); track status) {
                          <option [value]="status">{{ label(status) }}</option>
                        }
                      </select>
                    </label>
                    <label class="field-label">
                      <span>Queue</span>
                      <select name="scope" class="form-control" [(ngModel)]="model.scope">
                        <option value="project">This project</option>
                        <option value="global">Global inbox</option>
                      </select>
                    </label>
                    <label class="field-label">
                      <span>Runtime override</span>
                      <span class="field-hint">Workflow default when empty</span>
                      <select name="runtime" class="form-control" data-testid="task-runtime" [ngModel]="model.runtime" (ngModelChange)="onRuntimeChange($event)">
                        <option value="">Auto (workflow default)</option>
                        @for (rt of runtimeOptions; track rt) {
                          <option [value]="rt">{{ rt }}</option>
                        }
                      </select>
                    </label>
                    @if (model.runtime) {
                      <ralph-model-select
                        class="task-model-field"
                        data-testid="task-model"
                        [runtime]="model.runtime"
                        [model]="model.model"
                        (modelChange)="model.model = $event"
                      />
                    } @else {
                      <label class="field-label">
                        <span>Model override</span>
                        <input class="form-control" type="text" disabled placeholder="inherit" />
                      </label>
                    }
                  </div>

                  @if (editingId()) {
                    <div class="action-stack">
                      @if (model.status === 'backlog' || model.status === 'ready') {
                        <div class="action-card">
                          <div class="action-card-copy">
                            <p class="action-card-title">Workflow run</p>
                            <p class="action-card-hint">Save changes, then start the selected workflow for this task.</p>
                          </div>
                          <button
                            type="button"
                            class="btn btn-secondary"
                            data-testid="task-start-workflow"
                            [disabled]="startingTask() || !model.workflowId"
                            (click)="startEditedTask()"
                          >
                            {{ startingTask() ? 'Starting…' : 'Start workflow' }}
                          </button>
                        </div>
                      }
                      <div class="action-card">
                        <div class="action-card-copy">
                          <p class="action-card-title">Leaf plan</p>
                          @if (!editingTask()?.leafPlan) {
                            <p class="action-card-hint">Attach a checklist plan for a focused leaf run.</p>
                          } @else {
                            <p class="action-card-hint">
                              <span class="meta-tag leaf-tag">{{ editingTask()?.leafPlan?.title }}</span>
                            </p>
                          }
                        </div>
                        <div class="action-card-actions">
                          @if (!editingTask()?.leafPlan) {
                            <button type="button" class="btn btn-secondary" (click)="leafPlanChoiceOpen.set(true)">Create leaf plan</button>
                          } @else {
                            <button type="button" class="btn btn-secondary" [disabled]="startingTask()" (click)="startLeafPlan()">Run leaf plan</button>
                            <button type="button" class="btn btn-ghost" (click)="editLeafPlan()">Edit plan</button>
                          }
                        </div>
                      </div>
                    </div>
                  }
                </section>

                <section class="form-section form-section-card">
                  <div class="section-head">
                    <h3 class="section-legend">Target</h3>
                    <p class="section-hint">Where agents execute this task.</p>
                  </div>
                  <div class="target-segments" role="radiogroup" aria-label="Execution target">
                    <label class="target-segment" [class.selected]="model.targetMode === 'registered'">
                      <input type="radio" name="target" value="registered" [(ngModel)]="model.targetMode" />
                      <span class="segment-title">Registered project</span>
                      <span class="segment-desc">Use a workspace from your registry.</span>
                    </label>
                    <label class="target-segment" [class.selected]="model.targetMode === 'new-project'">
                      <input type="radio" name="target" value="new-project" [(ngModel)]="model.targetMode" />
                      <span class="segment-title">New project</span>
                      <span class="segment-desc">Bootstrap work in a new directory.</span>
                    </label>
                    <label class="target-segment" [class.selected]="model.targetMode === 'global'">
                      <input type="radio" name="target" value="global" [(ngModel)]="model.targetMode" />
                      <span class="segment-title">Global</span>
                      <span class="segment-desc">Run outside a single project tree.</span>
                    </label>
                  </div>

                  @if (model.targetMode === 'registered') {
                    <label class="field-label target-field">
                      <span>Project</span>
                      <select name="targetWorkspace" class="form-control" [(ngModel)]="model.targetWorkspaceRoot">
                        <option value="">Current project</option>
                        @for (ws of projects(); track ws.workspaceRoot) {
                          <option [value]="ws.workspaceRoot">{{ ws.label }} — {{ ws.projectRoot }}</option>
                        }
                      </select>
                    </label>
                  }
                  @if (model.targetMode === 'new-project') {
                    <label class="field-label target-field">
                      <span>New project directory path</span>
                      <input
                        type="text"
                        name="projectPath"
                        class="form-control"
                        [(ngModel)]="model.projectPath"
                        placeholder="/path/to/project"
                      />
                    </label>
                  }
                </section>

                @if (editingTask(); as task) {
                  <section class="form-section form-section-card run-history" data-testid="task-run-history">
                    <div class="section-head">
                      <h3 class="section-legend">Run history</h3>
                      <p class="section-hint">{{ task.attempts.length ? task.attempts.length + ' attempt(s)' : 'No runs yet' }}</p>
                    </div>
                    @if (!task.attempts.length) {
                      <p class="empty-runs">Start a workflow or leaf plan to record attempts here.</p>
                    } @else {
                      <ol class="attempt-timeline">
                        @for (attempt of task.attempts; track attempt.id) {
                          <li class="attempt-item">
                            <div class="attempt-main">
                              <span class="attempt-kind">{{ attempt.executionKind === 'leaf-plan' ? 'Leaf plan' : 'Workflow' }}</span>
                              <span class="attempt-outcome" [class]="attemptOutcomeClass(attempt)">
                                {{ attempt.outcome || attempt.status }}
                              </span>
                              @if (formatAttemptTime(attempt)) {
                                <span class="attempt-time">{{ formatAttemptTime(attempt) }}</span>
                              }
                              @if (attempt.summary || attempt.error) {
                                <p class="attempt-detail">{{ attempt.summary || attempt.error }}</p>
                              }
                            </div>
                            <div class="attempt-actions">
                              @if (attempt.runId) {
                                <a class="attempt-link" [routerLink]="['/workflows', 'runs', attempt.runId]" (click)="close()">View run</a>
                              } @else if (attempt.executionKind === 'leaf-plan' && (attempt.status === 'launching' || attempt.status === 'running')) {
                                <button type="button" class="btn btn-danger btn-compact" (click)="stopLeafPlan(attempt.id)">Stop</button>
                              } @else {
                                <span class="field-hint">Recording run…</span>
                              }
                            </div>
                          </li>
                        }
                      </ol>
                    }
                  </section>
                }
              </div>

              <footer class="modal-footer">
                <button type="button" class="btn btn-ghost" (click)="close()">Cancel</button>
                <button type="submit" class="btn btn-primary" [disabled]="!model.workflowId">
                  {{ editingId() ? 'Save changes' : 'Create task' }}
                </button>
              </footer>
            </form>
          </section>
        </div>
      }

      @if (showStatuses()) {
        <div class="hub-modal-backdrop" (click)="showStatuses.set(false)">
          <section
            class="modal-panel status-modal hub-modal-panel hub-modal-panel--compact"
            role="dialog"
            aria-modal="true"
            aria-labelledby="status-dialog-title"
            (click)="$event.stopPropagation()"
          >
            <header class="modal-header">
              <div>
                <p class="eyebrow">Board configuration</p>
                <h2 id="status-dialog-title" class="modal-title">Task statuses</h2>
              </div>
              <button type="button" class="close-btn" aria-label="Close dialog" (click)="showStatuses.set(false)">×</button>
            </header>

            <p class="modal-lede">Statuses become board columns. Move tasks out before deleting a status.</p>

            <div class="status-list">
              @for (status of statuses(); track status) {
                <div class="status-item">
                  <span class="status-name">{{ label(status) }}</span>
                  <button type="button" class="btn btn-ghost remove-btn" (click)="remove(status)">Remove</button>
                </div>
              }
            </div>

            <form class="add-status-form" (ngSubmit)="add()">
              <input
                type="text"
                name="newStatus"
                class="form-control"
                [(ngModel)]="newStatus"
                placeholder="e.g. In review"
              />
              <button type="submit" class="btn btn-primary" [disabled]="!newStatus.trim()">Add status</button>
            </form>
          </section>
        </div>
      }
      @if (leafPlanOpen()) {
        <div class="hub-modal-backdrop" (click)="leafPlanOpen.set(false)"><section class="modal-panel hub-modal-panel hub-modal-panel--compact" role="dialog" aria-modal="true" (click)="$event.stopPropagation()">
          <header class="modal-header"><div><p class="eyebrow">Leaf plan</p><h2 class="modal-title">{{ leafPlanTitle() }}</h2></div><button type="button" class="close-btn" (click)="leafPlanOpen.set(false)">×</button></header>
          <div class="hub-panel-card leaf-plan-form">
          <label class="field-label"><span>Plan title</span><input class="form-control" [(ngModel)]="leafPlanTitle" name="leafPlanTitle" /></label>
          <label class="field-label"><span>Checklist</span><textarea class="form-control" rows="14" [(ngModel)]="leafPlanContent" name="leafPlanContent"></textarea></label>
          </div>
          <footer class="hub-modal-footer"><button type="button" class="btn btn-ghost" (click)="leafPlanOpen.set(false)">Cancel</button><button type="button" class="btn btn-primary" (click)="saveLeafPlan()">Save leaf plan</button></footer>
        </section></div>
      }
      @if (leafPlanChoiceOpen()) {
        <div class="hub-modal-backdrop" (click)="leafPlanChoiceOpen.set(false)"><section class="modal-panel hub-modal-panel hub-modal-panel--compact" role="dialog" aria-modal="true" aria-label="Create leaf plan" (click)="$event.stopPropagation()">
          <header class="modal-header"><div><p class="eyebrow">Leaf plan</p><h2 class="modal-title">How would you like to create it?</h2></div><button type="button" class="close-btn" (click)="leafPlanChoiceOpen.set(false)">×</button></header>
          <div class="hub-panel-card"><p class="modal-lede">Create a checklist yourself, or use AI chat to draft one from this task.</p>
          <div class="execution-action"><button type="button" class="btn btn-primary" (click)="createLeafPlan()">Manual create</button><span class="field-hint">Open an editable starter plan now.</span></div>
          <div class="execution-action"><button type="button" class="btn btn-secondary" (click)="draftLeafPlanWithAi()">AI assisted</button><span class="field-hint">Open AI chat with this task already seeded.</span></div>
          </div>
        </section></div>
      }
    </main>
  `,
  styleUrl: './tasks.page.scss',
})
export class TasksPageComponent implements OnInit {
  private readonly api = inject(TasksSchedulesService);
  private readonly inventory = inject(TasksInventoryStore);
  private readonly route = inject(ActivatedRoute);
  private readonly workspace = inject(WorkspaceSelectorService);
  private readonly workflowsApi = inject(WorkflowsApi);
  private readonly errorDialog = inject(ErrorDialogService);
  private readonly assistant = inject(AssistantStore);

  readonly tasks = this.inventory.tasks;
  readonly statuses = this.inventory.statuses;
  readonly workflows = signal<readonly WorkflowListItem[]>([]);
  readonly workflowLoading = signal(true);
  readonly projects = this.workspace.workspaces;
  readonly loading = this.inventory.loading;
  readonly hasLoadedOnce = this.inventory.hasLoadedOnce;
  readonly showLoadingSkeleton = computed(() => shouldShowRouteSkeleton(this.loading(), this.hasLoadedOnce()));
  readonly error = this.inventory.error;
  readonly view = signal<'board' | 'list'>('board');
  readonly taskView = signal<'active-board' | 'backlog' | 'history'>('active-board');
  readonly visibleTasks = computed(() => {
    const view = this.taskView();
    if (view === 'backlog') return this.tasks().filter((task) => task.status === 'backlog');
    if (view === 'history') return this.tasks().filter((task) => this.isHistorical(task));
    return this.tasks().filter((task) => task.status !== 'backlog' && !this.isHistorical(task));
  });
  readonly boardStatuses = computed(() =>
    this.statuses().filter((status) => status !== 'backlog' && !this.isHistoricalStatus(status)),
  );
  readonly pageTitle = computed(() => {
    switch (this.taskView()) {
      case 'backlog': return 'Backlog';
      case 'history': return 'Task history';
      default: return 'Active board';
    }
  });
  readonly pageLede = computed(() => {
    switch (this.taskView()) {
      case 'backlog': return 'Capture and refine work before it is ready to enter the board.';
      case 'history': return 'Review completed and discarded work, including its most recent run outcome.';
      default: return 'Track work that is ready, in progress, under review, or blocked.';
    }
  });
  readonly emptyTitle = computed(() => {
    switch (this.taskView()) {
      case 'backlog': return 'Your backlog is clear';
      case 'history': return 'No task history yet';
      default: return 'No active tasks';
    }
  });
  readonly emptyHint = computed(() => {
    switch (this.taskView()) {
      case 'backlog': return 'Create a task to capture work before it is ready to run.';
      case 'history': return 'Completed and discarded tasks will appear here.';
      default: return 'Move a backlog task to a ready status when work can begin.';
    }
  });
  readonly open = signal(false);
  readonly editingId = signal<string | null>(null);
  readonly editingTask = computed(() => this.tasks().find((task) => task.id === this.editingId()) ?? null);
  readonly startingTask = signal(false);
  readonly leafPlanOpen = signal(false);
  readonly leafPlanChoiceOpen = signal(false);
  readonly leafPlanTitle = signal('');
  readonly leafPlanContent = signal('');
  readonly draggingTask = signal<DashboardTask | null>(null);
  readonly dragTargetStatus = signal<string | null>(null);
  readonly showStatuses = signal(false);

  newStatus = '';
  model = blank();
  readonly runtimeOptions = RUNTIME_OPTIONS;

  constructor() {
    effect(() => {
      this.workspace.selectedWorkspacePath?.();
      this.workspace.workspaces();
      const root = this.taskQueryWorkspaceRoot();
      this.inventory.hydrate(root);
      this.inventory.refresh(root);
    });
  }

  ngOnInit(): void {
    this.syncTaskViewFromRoute();
    this.route.paramMap.subscribe(() => this.syncTaskViewFromRoute());
    this.workspace.loadWorkspaces();
    if (!this.workflows().length) {
      this.workflowsApi.listWorkflows(undefined, { includeAuto: true }).subscribe({
        next: (x) => {
          this.workflows.set(x);
          this.workflowLoading.set(false);
        },
        error: () => this.workflowLoading.set(false),
      });
    } else {
      this.workflowLoading.set(false);
    }
  }

  private syncTaskViewFromRoute(): void {
    const routeView = this.route.snapshot.paramMap.get('taskView');
    if (routeView === 'backlog' || routeView === 'history' || routeView === 'active-board') {
      this.taskView.set(routeView);
    }
  }

  load(): void {
    this.inventory.refresh(this.taskQueryWorkspaceRoot());
  }

  label(s: string): string {
    return s.replaceAll('_', ' ');
  }

  statusClass(status: string): string {
    const slug = status.replaceAll('_', '-');
    const known = new Set(['backlog', 'ready', 'in-progress', 'review', 'blocked', 'completed', 'discarded']);
    return known.has(slug) ? `status-${slug}` : 'status-default';
  }

  formatTaskTime(iso: string): string {
    const date = new Date(iso);
    if (Number.isNaN(date.getTime())) return iso;
    return date.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
  }

  formatAttemptTime(attempt: DashboardAttempt): string {
    const iso = attempt.endedAt || attempt.startedAt;
    if (!iso) return '';
    return this.formatTaskTime(iso);
  }

  attemptOutcomeClass(attempt: DashboardAttempt): string {
    if (attempt.outcome === 'done') return 'outcome-done';
    if (attempt.outcome === 'blocked' || attempt.status === 'failed') return 'outcome-failed';
    if (attempt.status === 'launching' || attempt.status === 'running') return 'outcome-active';
    return '';
  }

  lastAttempt(t: DashboardTask) {
    return t.attempts?.[t.attempts.length - 1];
  }

  items(s: string): DashboardTask[] {
    return this.visibleTasks().filter((x) => x.status === s);
  }

  private isHistorical(task: DashboardTask): boolean {
    return this.isHistoricalStatus(task.status);
  }

  private isHistoricalStatus(status: string): boolean {
    return status === 'completed' || status === 'discarded';
  }

  target(t: DashboardTask): string {
    return t.targetMode === 'new-project'
      ? `New: ${t.projectPath || 'path pending'}`
      : t.targetMode === 'global'
        ? 'Global setup'
        : this.projects().find((x) => x.workspaceRoot === t.targetWorkspaceRoot)?.label || 'Current project';
  }

  /** Workspace whose project task store list/create/patch should use (selected sidebar project). */
  private taskQueryWorkspaceRoot(): string | undefined {
    const selectedPath = this.workspace.selectedWorkspacePath?.() ?? null;
    if (!selectedPath) {
      return undefined;
    }
    return this.workspace.workspaces().find((workspace) => workspace.path === selectedPath)?.workspaceRoot;
  }

  /** Workspace root for workflow execution (target project), not necessarily the task store key. */
  private taskExecutionWorkspaceRoot(task: DashboardTask): string | undefined {
    const target = task.targetWorkspaceRoot?.trim();
    if (target) {
      return target;
    }
    return this.taskQueryWorkspaceRoot();
  }

  create(): void {
    this.editingId.set(null);
    this.model = {
      ...blank(),
      workflowId: this.workflows()[0]?.id || '',
      status: this.statuses()[0] || 'backlog',
    };
    this.open.set(true);
  }

  edit(t: DashboardTask): void {
    this.editingId.set(t.id);
    this.model = {
      ...blank(),
      ...t,
      runtime: t.runtime ?? '',
      model: t.model ?? '',
      targetMode: t.targetMode || 'registered',
      targetWorkspaceRoot: t.targetWorkspaceRoot || '',
      projectPath: t.projectPath || '',
    };
    this.open.set(true);
  }

  onRuntimeChange(value: string): void {
    this.model = { ...this.model, runtime: value, model: value ? this.model.model : '' };
  }

  createLeafPlan(): void {
    const task = this.editingTask(); if (!task) return;
    this.leafPlanChoiceOpen.set(false);
    this.leafPlanTitle.set(task.title);
    this.leafPlanContent.set(`# ${task.title}\n\n## Task context\n\n${task.description || task.title}\n\nAcceptance criteria:\n${task.acceptanceCriteria || '(none provided)'}\n\n## TODOs\n\n- [ ] Investigate the task and identify the files and tests involved.\n- [ ] Implement the requested change with focused verification.\n- [ ] Run the relevant verification and record the result.\n`);
    this.leafPlanOpen.set(true);
  }

  draftLeafPlanWithAi(): void {
    const task = this.editingTask(); if (!task) return;
    this.leafPlanChoiceOpen.set(false);
    this.assistant.openWithPrefilledDraft(`Create a complete classic Ralph leaf plan for this task. Include actionable - [ ] TODOs and verification where useful. Return the proposed plan in one Markdown code block so I can review and save it.\n\nTitle: ${task.title}\nDescription: ${task.description || '(none)'}\nAcceptance criteria: ${task.acceptanceCriteria || '(none)'}`);
  }

  editLeafPlan(): void {
    const task = this.editingTask(); if (!task) return;
    this.api.getLeafPlan(task.id, this.taskQueryWorkspaceRoot()).subscribe({ next: (plan) => { this.leafPlanTitle.set(plan.title); this.leafPlanContent.set(plan.content); this.leafPlanOpen.set(true); }, error: (err) => void this.errorDialog.displayError(err, 'Leaf plan could not be loaded.') });
  }

  saveLeafPlan(): void {
    const id = this.editingId(); if (!id) return;
    this.api.saveLeafPlan(id, { title: this.leafPlanTitle(), content: this.leafPlanContent() }, this.taskQueryWorkspaceRoot()).subscribe({ next: () => { this.leafPlanOpen.set(false); this.load(); }, error: (err) => void this.errorDialog.displayError(err, 'Leaf plan could not be saved.') });
  }

  close(): void {
    this.open.set(false);
  }

  save(): void {
    const id = this.editingId();
    const storeRoot = this.taskQueryWorkspaceRoot();
    const req = id ? this.api.patchTask(id, this.model, storeRoot) : this.api.createTask(this.model, storeRoot);
    req.subscribe({
      next: () => {
        this.close();
        this.load();
      },
      error: (err) => {
        void this.errorDialog.displayError(err, 'Task could not be saved.');
      },
    });
  }

  move(task: DashboardTask, status: string): void {
    this.api.patchTask(task.id, { status }, this.taskQueryWorkspaceRoot()).subscribe({
      next: () => this.load(),
      error: (err) => {
        void this.errorDialog.displayError(err, 'Task status could not be updated.');
      },
    });
  }

  onDragStart(event: DragEvent, task: DashboardTask): void {
    this.draggingTask.set(task);
    event.dataTransfer?.setData('text/plain', task.id);
    if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
  }

  onDragOver(event: DragEvent, status: string): void {
    if (!this.draggingTask() || this.draggingTask()?.status === status) return;
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
    this.dragTargetStatus.set(status);
  }

  onDragLeave(status: string): void {
    if (this.dragTargetStatus() === status) this.dragTargetStatus.set(null);
  }

  onDrop(event: DragEvent, status: string): void {
    event.preventDefault();
    const task = this.draggingTask();
    this.onDragEnd();
    if (task && task.status !== status) this.move(task, status);
  }

  onDragEnd(): void {
    this.draggingTask.set(null);
    this.dragTargetStatus.set(null);
  }

  runNow(task: DashboardTask): void {
    this.launchTask(task);
  }

  startEditedTask(): void {
    const id = this.editingId();
    if (!id) return;
    this.startingTask.set(true);
    const storeRoot = this.taskQueryWorkspaceRoot();
    this.api.patchTask(id, this.model, storeRoot).subscribe({
      next: (task) => this.launchTask(task, true),
      error: (err) => {
        this.startingTask.set(false);
        void this.errorDialog.displayError(err, 'Task could not be saved before starting.');
      },
    });
  }

  startLeafPlan(): void {
    const task = this.editingTask(); if (!task) return;
    this.startingTask.set(true);
    this.api.launchLeafPlan(task.id, this.taskExecutionWorkspaceRoot(task)).subscribe({ next: () => { this.startingTask.set(false); this.close(); this.load(); }, error: (err) => { this.startingTask.set(false); void this.errorDialog.displayError(err, 'Leaf plan could not be started.'); } });
  }

  stopLeafPlan(attemptId: string): void {
    const task = this.editingTask(); if (!task) return;
    this.api.cancelLeafPlan(attemptId, this.taskExecutionWorkspaceRoot(task)).subscribe({ next: () => { this.close(); this.load(); }, error: (err) => void this.errorDialog.displayError(err, 'Leaf plan could not be stopped.') });
  }

  private launchTask(task: DashboardTask, closeEditor = false): void {
    this.api.launchTask(task.id, this.taskExecutionWorkspaceRoot(task)).subscribe({
      next: () => {
        this.startingTask.set(false);
        if (closeEditor) this.close();
        this.load();
      },
      error: (err) => {
        this.startingTask.set(false);
        void this.errorDialog.displayError(err, 'Task could not be started.');
      },
    });
  }

  add(): void {
    if (this.newStatus.trim()) {
      this.statuses.set([...this.statuses(), this.newStatus.trim()]);
      this.persist();
      this.newStatus = '';
    }
  }

  remove(s: string): void {
    this.statuses.set(this.statuses().filter((x) => x !== s));
    this.persist();
  }

  persist(): void {
    this.api.saveTaskStatuses(this.statuses()).subscribe({
      next: (x) => this.statuses.set(x),
      error: (e) => {
        void this.errorDialog.displayError(e, e.error?.error || 'Statuses could not be updated.');
      },
    });
  }
}
