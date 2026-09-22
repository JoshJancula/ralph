import { ChangeDetectionStrategy, Component, EventEmitter, Input, Output, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { PlanInventoryItem } from '../../services/api.service';

@Component({
  selector: 'ralph-plan-list-row',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div
      class="plan-row data-table-row"
      [class.is-expanded]="expanded()"
      role="link"
      tabindex="0"
      (click)="onOpen()"
      (keydown.enter)="onOpen()"
      (keydown.space)="$event.preventDefault(); onOpen()"
    >
      <div class="col-name data-table-priority">
        <div class="plan-name" [title]="item.name">{{ item.name }}</div>
        @if (item.planName && item.planName !== item.name) {
          <div class="plan-display-name">{{ item.planName }}</div>
        }
        <div class="plan-meta">
          <span class="plan-kind">{{ formatType(item.type) }}</span>
          @if (item.currentTodo?.content) {
            <span class="plan-todo" [title]="item.currentTodo?.content">{{ item.currentTodo?.content }}</span>
          }
        </div>
      </div>
      <div class="col-status data-table-priority">
        <div class="plan-status">
          <span class="status-icon" [class]="'status-' + getStatusLabel(item)" aria-hidden="true"></span>
          <span class="status-label status-text">{{ item.activeRun ? 'Live Ralph run' : getStatusLabel(item) }}</span>
          @if (item.activeRun; as run) {
            <span class="live-process-count">{{ run.liveProcesses }} process{{ run.liveProcesses === 1 ? '' : 'es' }}</span>
          }
        </div>
      </div>
      <div class="col-progress data-table-priority">
        @if (item.checkboxProgress.total > 0) {
          <div class="progress-block">
            <span
              class="progress-track"
              role="progressbar"
              [attr.aria-valuenow]="item.checkboxProgress.completed"
              [attr.aria-valuemin]="0"
              [attr.aria-valuemax]="item.checkboxProgress.total"
            >
              <span class="progress-fill" [style.width.%]="progressPercent(item)"></span>
            </span>
            <span class="status-progress">{{ item.checkboxProgress.completed }}/{{ item.checkboxProgress.total }}</span>
          </div>
        } @else {
          <span class="status-progress muted">—</span>
        }
      </div>
      <div class="col-project data-table-secondary data-table-tablet-hide">
        <span class="project-name">{{ extractProjectName(item.projectRoot) }}</span>
      </div>
      <div class="col-activity data-table-secondary">
        <span class="activity-time">{{ formatLastActivity(item.lastActivityMs) }}</span>
      </div>
      <div class="col-actions">
        <button
          type="button"
          class="data-table-expand"
          [attr.aria-expanded]="expanded()"
          [attr.aria-controls]="detailId"
          (click)="toggleDetail($event)"
        >
          {{ expanded() ? 'Less' : 'More' }}
        </button>
        <button type="button" class="btn btn-ghost touch-target" (click)="onOpenClick($event)" aria-label="Open plan">
          Open
        </button>
        @if (item.activeRunId) {
          <button type="button" class="btn btn-danger touch-target" (click)="onStopClick($event)" aria-label="Stop leaf plan">Stop</button>
        } @else {
          <button type="button" class="btn btn-secondary touch-target" (click)="onRunClick($event)" aria-label="Run leaf plan">Run</button>
        }
      </div>
      <div class="data-table-detail" [attr.id]="detailId" [hidden]="!expanded()">
        <dl>
          <dt>Type</dt>
          <dd>{{ formatType(item.type) }}</dd>
          <dt>Project</dt>
          <dd>{{ extractProjectName(item.projectRoot) }}</dd>
          <dt>Last activity</dt>
          <dd>{{ formatLastActivity(item.lastActivityMs) }}</dd>
          @if (item.activeRun; as run) {
            <dt>Live Ralph run</dt>
            <dd>{{ run.id }} · {{ run.liveProcesses }} live process{{ run.liveProcesses === 1 ? '' : 'es' }}</dd>
          }
          @if (item.currentTodo?.content) {
            <dt>Current TODO</dt>
            <dd>{{ item.currentTodo?.content }}</dd>
          }
        </dl>
      </div>
    </div>
  `,
  styles: `
    .plan-row {
      display: grid;
      grid-template-columns: minmax(0, 2.2fr) 7.5rem minmax(6.5rem, 1fr) minmax(0, 1fr) 7.5rem auto;
      gap: 0.5rem 1rem;
      padding: 0.8rem 0.9rem;
      border-bottom: 1px solid color-mix(in srgb, var(--border) 82%, transparent);
      align-items: center;
      font-size: 0.85rem;
      transition: background 0.15s ease, box-shadow 0.15s ease;
      cursor: pointer;
    }
    :host:nth-child(even) .plan-row {
      background: color-mix(in srgb, var(--surface-hover) 38%, transparent);
    }
    .plan-row:hover,
    :host:nth-child(even) .plan-row:hover {
      background: var(--table-row-hover);
    }
    .col-name {
      display: flex;
      flex-direction: column;
      gap: 0.2rem;
      min-width: 0;
    }
    .col-type,
    .col-status,
    .col-progress,
    .col-project,
    .col-activity,
    .col-actions {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      min-width: 0;
    }
    .col-actions {
      justify-content: flex-end;
      flex-wrap: wrap;
    }
    .plan-name {
      font-family: var(--monospace-font);
      font-weight: 600;
      color: var(--text-primary);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .plan-display-name {
      font-size: 0.8rem;
      color: var(--text-muted);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .plan-meta {
      display: flex;
      min-width: 0;
      align-items: baseline;
      gap: 0.5rem;
    }
    .plan-kind {
      flex: 0 0 auto;
      color: var(--text-muted);
      font-size: 0.72rem;
      font-weight: 600;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }
    .plan-todo {
      min-width: 0;
      overflow: hidden;
      color: var(--text-secondary);
      font-size: 0.78rem;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .plan-status {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    .status-icon {
      display: inline-block;
      width: 8px;
      height: 8px;
      border-radius: 50%;
      flex-shrink: 0;
    }
    .status-icon.status-active {
      background: var(--warning-text);
    }
    .status-icon.status-completed {
      background: var(--success-text);
    }
    .status-icon.status-waiting {
      background: var(--info-text);
    }
    .status-icon.status-pending {
      background: var(--text-muted);
    }
    .status-label {
      font-size: 0.82rem;
      font-weight: 600;
      color: var(--text-primary);
      text-transform: capitalize;
    }
    .live-process-count {
      color: var(--text-muted);
      font-family: var(--monospace-font);
      font-size: 0.72rem;
    }
    .progress-block {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
      min-width: 0;
      width: 100%;
    }
    .status-progress {
      font-size: 0.75rem;
      color: var(--text-muted);
      font-family: var(--monospace-font);
    }
    .project-name {
      font-size: 0.9rem;
      color: var(--text-primary);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .activity-time {
      font-size: 0.9rem;
      color: var(--text-muted);
      font-family: var(--monospace-font);
      white-space: nowrap;
    }

    @media (max-width: 1024px) {
      .plan-row {
        grid-template-columns: minmax(0, 1.6fr) 6.5rem minmax(5.5rem, 1fr) 7.5rem auto;
      }
    }

    @media (max-width: 720px) {
      .plan-row {
        grid-template-columns: minmax(0, 1fr) auto;
        gap: 0.5rem 0.75rem;
        padding: 0.85rem 0.9rem;
      }
      .col-project,
      .col-activity {
        display: none;
      }
      .col-status {
        grid-column: 1;
      }
      .col-progress {
        grid-column: 1;
      }
      .col-actions {
        grid-column: 2;
        grid-row: 1 / span 3;
        align-self: start;
        flex-direction: column;
      }
    }
  `,
})
export class PlanListRowComponent {
  @Input() item!: PlanInventoryItem;
  @Output() openPlan = new EventEmitter<PlanInventoryItem>();
  @Output() runPlan = new EventEmitter<PlanInventoryItem>();
  @Output() stopPlan = new EventEmitter<PlanInventoryItem>();

  readonly expanded = signal(false);

  get detailId(): string {
    return `plan-detail-${this.item?.id ?? 'unknown'}`;
  }

  toggleDetail(event: Event): void {
    event.stopPropagation();
    this.expanded.update((v) => !v);
  }

  onOpen(): void {
    this.openPlan.emit(this.item);
  }

  onOpenClick(event: Event): void {
    event.stopPropagation();
    this.onOpen();
  }

  onRunClick(event: Event): void { event.stopPropagation(); this.runPlan.emit(this.item); }
  onStopClick(event: Event): void { event.stopPropagation(); this.stopPlan.emit(this.item); }

  getStatusLabel(item: PlanInventoryItem): string {
    if (item.activeRun) {
      return 'active';
    }
    if (!item.hasLatestRun) {
      return 'pending';
    }
    if (item.checkboxProgress.total === 0) {
      return 'completed';
    }
    if (item.checkboxProgress.completed === item.checkboxProgress.total) {
      return 'completed';
    }
    return 'active';
  }

  progressPercent(item: PlanInventoryItem): number {
    if (!item.checkboxProgress.total) {
      return 0;
    }
    return Math.min(100, Math.round((item.checkboxProgress.completed / item.checkboxProgress.total) * 100));
  }

  formatType(type: string): string {
    const typeMap: Record<string, string> = {
      leaf: 'Leaf',
      'generated-control': 'Generated',
      supplied: 'Supplied',
      'workflow-derived': 'Workflow',
    };
    return typeMap[type] || type;
  }

  extractProjectName(projectRoot: string): string {
    const parts = projectRoot.split('/').filter(Boolean);
    return parts[parts.length - 1] || projectRoot;
  }

  formatLastActivity(ms: number): string {
    const now = Date.now();
    const diff = now - ms;
    const seconds = Math.floor(diff / 1000);
    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (days > 0) {
      return `${days}d ago`;
    } else if (hours > 0) {
      return `${hours}h ago`;
    } else if (minutes > 0) {
      return `${minutes}m ago`;
    } else if (seconds > 0) {
      return `${seconds}s ago`;
    }
    return 'just now';
  }
}
