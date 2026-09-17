import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';

export type DashboardTaskStatus = string;
export interface DashboardLeafPlan { path: string; title: string; updatedAt: string; }
export interface DashboardAttempt { id: string; runId?: string; executionKind?: 'workflow' | 'leaf-plan'; planPath?: string; status: string; logPath: string; startedAt?: string; endedAt?: string; workflowId?: string; autoRoute?: boolean; outcome?: 'done' | 'blocked' | 'needs_human' | 'missing'; summary?: string; error?: string; scheduleId?: string; }
export interface DashboardTask { id: string; title: string; description?: string; acceptanceCriteria?: string; workflowId: string; runtime?: string; model?: string; leafPlan?: DashboardLeafPlan; autoRecommendation?: string; scope: 'project' | 'global'; targetMode?: 'registered' | 'new-project' | 'global'; targetWorkspaceRoot?: string; projectPath?: string; parentTaskId?: string; status: DashboardTaskStatus; failureCount?: number; createdAt: string; updatedAt: string; attempts: DashboardAttempt[]; }
export type LaunchTaskOverrides = { readonly runtime?: string; readonly model?: string };
/** Built-in task worker: `one` runs a single task at a time, `all` keeps up to `maxConcurrent` running. `status` is the board column it pulls tasks from. */
export interface DashboardTaskWorker { mode: 'one' | 'all'; maxConcurrent: number; status: string; }
export interface DashboardSchedule { id: string; name: string; scope?: 'project' | 'global'; workflowId: string; cron: string; timezone: string; enabled: boolean; brief?: string; worker?: DashboardTaskWorker; targetWorkspaceRoot?: string; nextRunAt?: string; lastRunAt?: string; lastError?: string; consecutiveFailures?: number; activeAttempt?: DashboardAttempt; activeTaskIds?: string[]; }
/** `worker: null` converts a task worker back into a workflow schedule. */
export type DashboardSchedulePatch = Partial<Omit<DashboardSchedule, 'worker'>> & { worker?: DashboardTaskWorker | null };
@Injectable({ providedIn: 'root' })
export class TasksSchedulesService {
  private readonly http = inject(HttpClient);
  listTasks(workspaceRoot?: string) {
    return this.http.get<DashboardTask[]>('/api/tasks', { params: workspaceRoot ? { workspaceRoot } : {} });
  }
  listTaskStatuses() { return this.http.get<string[]>('/api/task-statuses'); }
  saveTaskStatuses(statuses: string[]) { return this.http.put<string[]>('/api/task-statuses', { statuses }); }
  createTask(body: Partial<DashboardTask>, workspaceRoot?: string) {
    return this.http.post<DashboardTask>('/api/tasks', body, { params: workspaceRoot ? { workspaceRoot } : {} });
  }
  patchTask(id: string, body: Partial<DashboardTask>, workspaceRoot?: string) {
    return this.http.patch<DashboardTask>(`/api/tasks/${encodeURIComponent(id)}`, body, {
      params: workspaceRoot ? { workspaceRoot } : {},
    });
  }
  launchTask(id: string, workspaceRoot?: string, overrides?: LaunchTaskOverrides) {
    const body: { runtime?: string; model?: string } = {};
    if (overrides?.runtime) {
      body.runtime = overrides.runtime;
    }
    if (overrides?.runtime && overrides?.model) {
      body.model = overrides.model;
    }
    return this.http.post<{ task: DashboardTask; attempt: DashboardAttempt }>(
      `/api/tasks/${encodeURIComponent(id)}/launch`,
      body,
      { params: workspaceRoot ? { workspaceRoot } : {} },
    );
  }
  launchLeafPlan(id: string, workspaceRoot?: string) { return this.http.post<{ task: DashboardTask; attempt: DashboardAttempt }>(`/api/tasks/${encodeURIComponent(id)}/launch-leaf-plan`, {}, { params: workspaceRoot ? { workspaceRoot } : {} }); }
  getLeafPlan(id: string, workspaceRoot?: string) { return this.http.get<DashboardLeafPlan & { content: string }>(`/api/tasks/${encodeURIComponent(id)}/leaf-plan`, { params: workspaceRoot ? { workspaceRoot } : {} }); }
  saveLeafPlan(id: string, body: { title: string; content: string }, workspaceRoot?: string) { return this.http.put<DashboardTask>(`/api/tasks/${encodeURIComponent(id)}/leaf-plan`, body, { params: workspaceRoot ? { workspaceRoot } : {} }); }
  cancelLeafPlan(attemptId: string, workspaceRoot?: string) { return this.http.post<{ ok: true }>(`/api/leaf-runs/${encodeURIComponent(attemptId)}/cancel`, {}, { params: workspaceRoot ? { workspaceRoot } : {} }); }
  listSchedules() { return this.http.get<DashboardSchedule[]>('/api/schedules'); }
  createSchedule(body: DashboardSchedulePatch) { return this.http.post<DashboardSchedule>('/api/schedules', body); }
  patchSchedule(id: string, body: DashboardSchedulePatch) { return this.http.patch<DashboardSchedule>(`/api/schedules/${encodeURIComponent(id)}`, body); }
  preview(cron: string, timezone: string) { return this.http.post<{ times: string[] }>('/api/schedules/preview', { cron, timezone }); }
  runSchedule(id: string) { return this.http.post<DashboardSchedule>(`/api/schedules/${encodeURIComponent(id)}/run`, {}); }
  templates() { return this.http.get<Array<{ id: string; category: string; purpose: string; outputs: string; stageCount: number; safety: string; installable: boolean }>>('/api/dashboard-templates'); }
  installTemplate(id: string, scope: 'project' | 'global' = 'project') { return this.http.post(`/api/dashboard-templates/${encodeURIComponent(id)}/install`, { scope }); }
}
