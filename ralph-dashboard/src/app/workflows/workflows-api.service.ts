import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { EMPTY, Observable, fromEvent } from 'rxjs';
import { takeUntil } from 'rxjs/operators';
import type {
  CreateWorkflowCommand,
  CustomizeWorkflowCommand,
  CustomizeWorkflowResponse,
  DashboardCapabilities,
  ModelDescriptor,
  RespondActionCommand,
  RunListItem,
  RunsInventoryResponse,
  RunStatus,
  RuntimeDescriptor,
  StartWorkflowCommand,
  StartWorkflowResponse,
  UpdateWorkflowCommand,
  WorkflowDetail,
  WorkflowListItem,
  WorkflowRoutingPatch,
  WorkflowScope,
  WritableWorkflowScope,
} from './workflow.types';

/** Thin Observable HTTP layer over the workflow-api.ts server routes, following ApiService's existing style. */
@Injectable({ providedIn: 'root' })
export class WorkflowsApi {
  private readonly http = inject(HttpClient);

  private paramsWithWorkspace(workspaceRoot?: string): Record<string, string> {
    return workspaceRoot ? { workspaceRoot } : {};
  }

  /** Cancels the source when the given AbortSignal fires; HttpClient has no native signal option. */
  private withAbort<T>(source: Observable<T>, signal?: AbortSignal): Observable<T> {
    if (!signal) {
      return source;
    }
    if (signal.aborted) {
      return EMPTY;
    }
    return source.pipe(takeUntil(fromEvent(signal, 'abort')));
  }

  listWorkflows(workspaceRoot?: string, options?: { signal?: AbortSignal; includeAuto?: boolean }): Observable<readonly WorkflowListItem[]> {
    const params = this.paramsWithWorkspace(workspaceRoot);
    if (options?.includeAuto) {
      params['includeAuto'] = '1';
    }
    return this.withAbort(
      this.http.get<readonly WorkflowListItem[]>('/api/workflows', {
        params,
      }),
      options?.signal,
    );
  }

  getWorkflow(id: string, workspaceRoot?: string, scope?: WorkflowScope): Observable<WorkflowDetail> {
    const params = { ...this.paramsWithWorkspace(workspaceRoot) };
    if (scope) {
      params['scope'] = scope;
    }
    return this.http.get<WorkflowDetail>(`/api/workflows/${encodeURIComponent(id)}`, { params });
  }

  createWorkflow(command: CreateWorkflowCommand, workspaceRoot?: string): Observable<{ id: string; scope: string; sha256: string }> {
    return this.http.post<{ id: string; scope: string; sha256: string }>('/api/workflows', command, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  updateWorkflow(
    id: string,
    command: UpdateWorkflowCommand,
    workspaceRoot?: string,
    scope?: WritableWorkflowScope | WorkflowScope,
  ): Observable<{ sha256: string }> {
    const params = { ...this.paramsWithWorkspace(workspaceRoot) };
    if (scope) {
      params['scope'] = scope;
    }
    return this.http.put<{ sha256: string }>(`/api/workflows/${encodeURIComponent(id)}`, command, { params });
  }

  customizeWorkflow(
    id: string,
    command: CustomizeWorkflowCommand,
    workspaceRoot?: string,
  ): Observable<CustomizeWorkflowResponse> {
    return this.http.post<CustomizeWorkflowResponse>(`/api/workflows/${encodeURIComponent(id)}/customize`, command, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  patchWorkflowRouting(
    id: string,
    scope: WritableWorkflowScope,
    patch: WorkflowRoutingPatch,
    workspaceRoot?: string,
  ): Observable<{ scope: WritableWorkflowScope; sha256: string }> {
    const params = { ...this.paramsWithWorkspace(workspaceRoot), scope };
    return this.http.patch<{ scope: WritableWorkflowScope; sha256: string }>(
      `/api/workflows/${encodeURIComponent(id)}/routing`,
      patch,
      { params },
    );
  }

  deleteWorkflow(id: string, scope: 'project' | 'global', workspaceRoot?: string): Observable<void> {
    return this.http.delete<void>(`/api/workflows/${encodeURIComponent(id)}`, {
      params: { ...this.paramsWithWorkspace(workspaceRoot), scope },
    });
  }

  listWorkflowRuns(id: string, workspaceRoot?: string): Observable<readonly RunListItem[]> {
    return this.http.get<readonly RunListItem[]>(`/api/workflows/${encodeURIComponent(id)}/runs`, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  listRuns(
    filters: { workflow?: string; state?: string } = {},
    workspaceRoot?: string,
    options?: { signal?: AbortSignal },
  ): Observable<readonly RunListItem[]> {
    const params: Record<string, string> = { ...this.paramsWithWorkspace(workspaceRoot) };
    if (filters.workflow) params['workflow'] = filters.workflow;
    if (filters.state) params['state'] = filters.state;
    return this.withAbort(
      this.http.get<readonly RunListItem[]>('/api/workflow-runs', { params }),
      options?.signal,
    );
  }

  listAllRuns(workspaceRoot?: string, options?: { signal?: AbortSignal }): Observable<RunsInventoryResponse | readonly RunListItem[]> {
    return this.withAbort(this.http.get<RunsInventoryResponse | readonly RunListItem[]>('/api/runs', { params: this.paramsWithWorkspace(workspaceRoot) }), options?.signal);
  }

  getRunStatus(runId: string, workspaceRoot?: string): Observable<RunStatus> {
    return this.http.get<RunStatus>(`/api/workflow-runs/${encodeURIComponent(runId)}`, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  listRuntimes(): Observable<readonly RuntimeDescriptor[]> {
    return this.http.get<readonly RuntimeDescriptor[]>('/api/workflow-runtimes');
  }

  listModels(runtime: string, workspaceRoot?: string): Observable<readonly ModelDescriptor[]> {
    return this.http.get<readonly ModelDescriptor[]>(`/api/workflow-runtimes/${encodeURIComponent(runtime)}/models`, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  startWorkflow(id: string, command: StartWorkflowCommand, workspaceRoot?: string): Observable<StartWorkflowResponse> {
    return this.http.post<StartWorkflowResponse>(`/api/workflows/${encodeURIComponent(id)}/start`, command, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  cancelRun(runId: string, workspaceRoot?: string): Observable<{ ok: true }> {
    return this.http.post<{ ok: true }>(
      `/api/workflow-runs/${encodeURIComponent(runId)}/cancel`,
      {},
      { params: this.paramsWithWorkspace(workspaceRoot) },
    );
  }

  resumeRun(runId: string, workspaceRoot?: string): Observable<{ ok: true }> {
    return this.http.post<{ ok: true }>(
      `/api/workflow-runs/${encodeURIComponent(runId)}/resume`,
      {},
      { params: this.paramsWithWorkspace(workspaceRoot) },
    );
  }

  resetRun(runId: string, command: { stage?: string; all?: boolean }, workspaceRoot?: string): Observable<{ ok: true }> {
    return this.http.post<{ ok: true }>(`/api/workflow-runs/${encodeURIComponent(runId)}/reset`, command, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  listRunActions(runId: string, workspaceRoot?: string): Observable<unknown> {
    return this.http.get<unknown>(`/api/workflow-runs/${encodeURIComponent(runId)}/actions`, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  respondRunAction(runId: string, command: RespondActionCommand, workspaceRoot?: string): Observable<{ ok: true }> {
    return this.http.post<{ ok: true }>(`/api/workflow-runs/${encodeURIComponent(runId)}/actions/respond`, command, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  fetchCapabilities(): Observable<DashboardCapabilities> {
    return this.http.get<DashboardCapabilities>('/api/capabilities');
  }
}
