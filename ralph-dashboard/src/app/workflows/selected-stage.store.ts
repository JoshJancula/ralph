import { Injectable, signal } from '@angular/core';

/**
 * Shared selection between the workflow display graph and the stage inspector.
 * Scoped to a workflow id so navigating between definitions clears stale picks.
 */
@Injectable({ providedIn: 'root' })
export class SelectedStageStore {
  readonly workflowId = signal<string | null>(null);
  readonly stageId = signal<string | null>(null);

  /** Reset selection when the open workflow changes. */
  bindWorkflow(workflowId: string): void {
    if (this.workflowId() === workflowId) {
      return;
    }
    this.workflowId.set(workflowId);
    this.stageId.set(null);
  }

  select(workflowId: string, stageId: string): void {
    this.workflowId.set(workflowId);
    this.stageId.set(stageId);
  }

  clear(): void {
    this.stageId.set(null);
  }
}
