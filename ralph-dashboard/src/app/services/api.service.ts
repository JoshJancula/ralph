import { HttpClient, HttpErrorResponse } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { EMPTY, Observable, fromEvent, throwError } from 'rxjs';
import { catchError, takeUntil } from 'rxjs/operators';
import { ResourceIdentity, ResourceIdentityCodec, ResourceError, ResourceErrorBuilder } from '../../shared';

export interface Root {
  key: string;
  label: string;
  exists: boolean;
}

export interface Listing {
  root: string;
  path: string;
  parent: string | null;
  entries: ListingEntry[];
}

export interface ListingEntry {
  name: string;
  path: string;
  type: 'file' | 'dir';
  size: number;
  mtime: number;
  /** Present when aggregating multiple `.ralph-workspace` logs or artifact trees. */
  workspaceRoot?: string;
}

export interface FileChunk {
  content: string;
  size: number;
  offset: number;
  nextOffset: number;
}

export interface WorkflowStageLogResponse {
  runId: string;
  stageId: string;
  attempt: number;
  content: string;
}

export interface StructuredErrorResponse {
  code: 'NOT_FOUND' | 'FORBIDDEN' | 'STALE_RESOURCE' | 'INVALID_REQUEST' | 'UNKNOWN';
  message: string;
  requestedPath?: string;
  resolvedPath?: string;
  title: string;
  explanation: string;
  recoverable: boolean;
  suggestedActions: string[];
}

export type TemplateName = 'plan' | 'orchestration';

export interface Template {
  name: TemplateName;
  content: string;
}

export interface WorkspaceInfo {
  root: string;
}

export interface WorkspaceRegistry {
  path: string;
  workspaceRoot: string;
  projectRoot: string;
  label: string;
  exists: boolean;
  sections?: Record<string, boolean>;
  lastSeen?: string;
  planKey?: string;
  runtime?: string;
}

export interface MetricsSummaryOverall {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  cache_hit_ratio: number;
  elapsed_seconds: number;
  count: number;
  /** Present when summaries include aggregated tool-call counts (plan runs). */
  tool_calls_total?: number;
}

export interface RuntimeOverlayMetrics {
  native_hooks_effective: boolean;
  mcp_effective: boolean;
  native_hook_events: number;
  hook_compactions: number;
  hook_rewrites: number;
  hook_original_bytes: number;
  hook_compacted_bytes: number;
  hook_bytes_saved: number;
  runtime_overlay_mode: string;
  runtime_overlay_warnings: string[];
}

/** Per-category tool call counters from Ralph usage accounting. */
export interface ToolCallClassificationMetrics {
  ralph_proxy_calls: number;
  ralph_knowledge_calls: number;
  other_mcp_calls: number;
  native_read_like_calls: number;
  native_write_like_calls: number;
  native_file_read_calls: number;
  native_read_compatibility_calls: number;
  native_search_calls: number;
  native_shell_calls: number;
  ralph_mcp_calls: number;
  runtime_hook_rewrite_calls: number;
  runtime_hook_compaction_calls: number;
  unknown_tool_calls: number;
}

export interface ModelBreakdownItem {
  runtime: string;
  role?: string;
  modelSource?: string;
  model: string;
  invocations: number;
  elapsed_seconds: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  cache_hit_ratio: number;
  tool_calls_total?: number;
  overlay?: RuntimeOverlayMetrics;
  tool_calls?: ToolCallClassificationMetrics;
}

export interface MetricsSummaryItem {
  path: string;
  plan_key: string;
  artifact_ns: string;
  workspace_root: string;
  project_root: string;
  stage_id?: string;
  model?: string;
  runtime?: string;
  role?: string;
  modelSource?: string;
  started_at?: string;
  ended_at?: string;
  elapsed_seconds: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  cache_hit_ratio: number;
  tool_calls_total?: number;
  model_breakdown?: ModelBreakdownItem[];
  overlay?: RuntimeOverlayMetrics;
  tool_calls?: ToolCallClassificationMetrics;
}

export interface MetricsProjectRollup {
  workspace_root: string;
  project_root: string;
  label: string;
  overall: MetricsSummaryOverall;
  plans: MetricsSummaryItem[];
  orchestrations: MetricsSummaryItem[];
}

export interface MetricsSummary {
  overall: MetricsSummaryOverall;
  plans: MetricsSummaryItem[];
  orchestrations: MetricsSummaryItem[];
  projects: MetricsProjectRollup[];
}

export interface MetricsInsightsSummary {
  date_scope: {
    from: string | null;
    to: string | null;
    label: string;
    run_count: number;
  };
  units: {
    tokens: 'tokens';
    elapsed: 'seconds';
    tool_calls: 'calls';
  };
  headline: {
    total_tokens: number;
    input_tokens: number;
    output_tokens: number;
    cache_read_input_tokens: number;
    cache_hit_ratio: number;
    elapsed_seconds: number;
    tool_calls_total: number;
    run_count: number;
  };
  trend: {
    direction: 'up' | 'down' | 'flat' | 'unknown';
    recent_tokens: number;
    prior_tokens: number;
    delta_tokens: number;
    delta_percent: number | null;
    recent_run_count: number;
    prior_run_count: number;
  };
  drivers: Array<{
    kind: 'runtime' | 'model';
    label: string;
    exact_value: string;
    total_tokens: number;
    share_percent: number;
    runs: number;
  }>;
  anomalies: Array<{
    code: string;
    severity: 'info' | 'warn';
    message: string;
  }>;
  drilldowns: Array<{ id: string; label: string; target: 'breakdown' | 'detail' }>;
  filter_options: {
    runtimes: string[];
    models: Array<{ label: string; exact_value: string }>;
  };
}

export interface MetricsBreakdownRow {
  runtime: string;
  model?: string;
  model_label?: string;
  model_exact?: string;
  model_count?: number;
  runs: number;
  invocations: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  total_tokens: number;
  tool_calls_total: number;
  cache_hit_ratio: number;
  max_turn_total_tokens: number;
  elapsed_seconds: number;
}

export interface MetricsRunModelRow {
  runtime: string;
  model: string;
  model_label: string;
  model_exact: string;
  invocations: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  total_tokens: number;
  tool_calls_total: number;
  elapsed_seconds: number;
}

export interface MetricsBreakdownRunRow {
  kind: 'plan' | 'orchestration';
  path: string;
  plan_key: string;
  stage_id?: string;
  workspace_root: string;
  runtime: string;
  model_label: string;
  model_exact: string;
  model_count?: number;
  models?: MetricsRunModelRow[];
  started_at?: string;
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  total_tokens: number;
  tool_calls_total: number;
  cache_hit_ratio: number;
  elapsed_seconds: number;
}

export interface MetricsBreakdownResponse {
  date_scope: {
    from: string | null;
    to: string | null;
    label: string;
  };
  units: MetricsInsightsSummary['units'];
  filtered_run_count: number;
  total_run_count: number;
  runtime_rows: MetricsBreakdownRow[];
  model_rows: MetricsBreakdownRow[];
  run_rows: MetricsBreakdownRunRow[];
  page: {
    offset: number;
    limit: number;
    total: number;
  };
  sort: {
    by: string;
    dir: 'asc' | 'desc';
  };
}

export interface MetricsDetailResponse {
  plan_key: string;
  kind: 'plan' | 'orchestration' | null;
  item: MetricsSummaryItem | null;
  related: MetricsSummaryItem[];
}

export interface MetricsQueryFilters {
  workspaceRoot?: string;
  kind?: 'all' | 'plan' | 'orchestration';
  runtime?: string;
  model?: string;
  dateFrom?: string;
  dateTo?: string;
  offset?: number;
  limit?: number;
  sortBy?: string;
  sortDir?: 'asc' | 'desc';
}

/** Optional AbortSignal for request cancellation on route/filter changes. */
export interface ApiRequestOptions {
  signal?: AbortSignal;
}

export interface DiscoverPatternSummary {
  pattern_id: string;
  count: number;
  description?: string;
}

export interface DiscoverReport {
  schema_version: number;
  kind: string;
  generated_at?: string;
  plan_key?: string;
  limitations?: string[];
  sequence_patterns?: DiscoverPatternSummary[];
  aggregate_findings?: Record<string, unknown>[];
  runtime_differences?: Record<string, unknown>[];
  high_token_low_cache_invocations?: Record<string, unknown>[];
}

export interface DiscoverReportResponse {
  plan_key: string;
  path: string;
  workspace_root: string;
  project_root: string;
  report: DiscoverReport;
}

export interface RalphFrameworkRootResponse {
  projectRoot: string | null;
}

export interface GraphRunSummary {
  namespace: string;
  runId: string;
  isLatest: boolean;
  status: string;
  startedAt: string | null;
  nodeCount: number;
}

export interface PlanInventoryItem {
  id: string;
  name: string;
  path: string;
  projectRoot: string;
  type: 'leaf' | 'generated-control' | 'supplied' | 'workflow-derived';
  planName?: string;
  overview?: string;
  isProject: boolean;
  checkboxProgress: { completed: number; total: number };
  currentTodo?: { id: string; content: string };
  lastActivityMs: number;
  hasLatestRun: boolean;
  activeRunId?: string;
  activeRun?: PlanActiveRun;
}

export interface PlanActiveRun {
  id: string;
  ownerPid: number | null;
  ownerAlive: boolean;
  liveProcesses: number;
  startedAt: string | null;
}

export interface PlanInventoryResponse {
  items: PlanInventoryItem[];
  pageInfo: {
    cursor?: string;
    hasMore: boolean;
    total: number;
  };
  appliedFilters: Record<string, unknown>;
  counts: {
    total: number;
    filtered: number;
  };
  activityDiscoveryError?: string;
}

export interface DelegatedRunRecord {
  delegatedRunId: string;
  runtime: string;
  role?: string;
  workspaceMode: string;
  status: string;
  verification?: string;
  usage: Record<string, number>;
}

/** @deprecated Components will migrate to DelegatedRunRecord in the UI TODO. */
export interface BrokeredChildState {
  delegationId: string;
  runtime?: string;
  status: string;
  task?: string;
  resultArtifact?: string;
  usage?: Record<string, number>;
}

export interface NativeSubagentEvent {
  event: string;
  timestamp?: string;
  details?: Record<string, unknown>;
}

export interface GraphUsageSummary {
  parent: Record<string, number>;
  delegatedRuns?: Record<string, number>;
  total: Record<string, number>;
  /** @deprecated Components will migrate to delegatedRuns in the UI TODO. */
  brokeredChildren?: Record<string, number>;
}

export interface GraphNodeAttempt {
  attemptId: string;
  outcome: string;
  exitCode?: number;
  startedAt?: string;
  finishedAt?: string;
  runtime?: string;
  role?: string;
  modelSource?: string;
  nativeSubagents?: string;
  /** @deprecated Runtime payloads use nativeSubagents. */
  subagents?: string;
  /** @deprecated Components will migrate to nativeSubagents in the UI TODO. */
  nativeSubagentMode?: string;
  reason?: string;
  /** V2 observability metadata recorded by the scheduler for this attempt. */
  workspaceMode?: string;
  workspacePath?: string;
  writeScopes?: string[];
  frozenBase?: string;
  changesetBaseline?: string;
  changesetHash?: string;
  conflictArtifact?: string;
  crossRuntimeMode?: string;
  integrationInputs?: string[];
  integrationResultIdentity?: string;
  gateOutcome?: string;
  gateResultPath?: string;
  publishReadiness?: Record<string, unknown>;
  changesetManifest?: string;
  usageSnapshot?: Record<string, unknown>;
  admissionSummary?: Record<string, unknown>;
  repairEpoch?: string;
}

export interface GraphNodeState {
  nodeId: string;
  status: string;
  attempts: GraphNodeAttempt[];
  lastAttemptId?: string;
  runtime?: string;
  role?: string;
  modelSource?: string;
  nativeSubagents?: string;
  /** @deprecated Components will migrate to nativeSubagents in the UI TODO. */
  nativeSubagentMode?: string;
  /** V2 observability metadata merged from the latest attempt. */
  workspaceMode?: string;
  workspacePath?: string;
  writeScopes?: string[];
  frozenBase?: string;
  changesetBaseline?: string;
  changesetHash?: string;
  conflictArtifact?: string;
  crossRuntimeMode?: string;
  integrationInputs?: string[];
  integrationResultIdentity?: string;
  gateOutcome?: string;
  gateResultPath?: string;
  publishReadiness?: Record<string, unknown>;
  changesetManifest?: string;
  usageSnapshot?: Record<string, unknown>;
  admissionSummary?: Record<string, unknown>;
  repairEpoch?: string;
  delegatedRuns?: DelegatedRunRecord[];
  /** @deprecated Components will migrate to delegatedRuns in the UI TODO. */
  brokeredChildren?: BrokeredChildState[];
  nativeSubagentEvents?: NativeSubagentEvent[];
}

export interface GraphRunDetail {
  namespace: string;
  runId: string;
  run: Record<string, unknown>;
  nodes: GraphNodeState[];
  graph: Record<string, unknown>;
  usage?: GraphUsageSummary;
  concurrencyReductions?: string[];
}

export interface GraphRunsResponse {
  runs: GraphRunSummary[];
}

export type SavingsPathName =
  | 'pre_tool_rewrite'
  | 'hook_compaction'
  | 'proxy_shell_compaction'
  | 'result_windowing';

export interface SavingsBucket {
  pre_optimization_bytes: number;
  post_optimization_bytes: number;
  saved_bytes: number;
  count: number;
  hidden_from_context?: number;
  hidden_from_context_tokens?: number;
  pre_optimization_tokens: number;
  post_optimization_tokens: number;
  saved_tokens: number;
  token_cap_triggers: number;
  savings_percent?: number;
  savings_percent_tokens?: number;
  status?: string;
  status_label?: string;
  gross_hidden_bytes?: number;
  gross_hidden_tokens?: number;
  gross_readback_bytes?: number;
  gross_readback_tokens?: number;
  net_readback_cost_bytes?: number;
  effective_windowing_savings_rate?: number;
  compaction_measured_not_applied_bytes?: number;
}

export interface SessionUsage {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  prompt_bytes: number;
  tool_calls_total: number;
}

export interface ToolOutputCounterfactual {
  hypothetical_without_ralph_bytes: number;
  actual_with_ralph_bytes: number;
  net_savings_bytes: number;
  hypothetical_without_ralph_tokens: number;
  actual_with_ralph_tokens: number;
  net_savings_tokens: number;
  net_savings_percent: number;
  compaction_measured_not_applied_bytes: number;
  compaction_measured_not_applied_tokens: number;
}

export interface ReadbackSummary {
  envelope_count: number;
  readback_count: number;
  raw_readback_count: number;
  compacted_readback_count: number;
  readback_bytes: number;
  envelope_original_bytes: number;
  full_preview_rereads: number;
  raw_readback_share: number;
  readback_negation_rate: number;
  gross_readback_bytes: number;
  gross_readback_tokens: number;
  net_consumed_bytes: number;
  net_consumed_tokens: number;
  effective_windowing_savings_rate: number;
}

export interface SavingsReport {
  schema_version: number;
  kind: 'ralph_benchmark_report';
  run_count: number;
  date_range: {
    started_at: string | null;
    ended_at: string | null;
  };
  saved_bytes: number;
  saved_tokens: number;
  savings_percent: number;
  session_usage: SessionUsage;
  tool_output_counterfactual: ToolOutputCounterfactual;
  per_path: Record<SavingsPathName, SavingsBucket>;
  cache: {
    cache_read_tokens: number;
    cache_hit_ratio: number;
  };
  could_have_saved: {
    compaction_measured_not_applied_bytes: number;
  };
  readback_summary?: ReadbackSummary;
}

@Injectable({
  providedIn: 'root',
})
export class ApiService {
  private readonly http = inject(HttpClient);

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

  fetchWorkspace(): Observable<WorkspaceInfo> {
    return this.http.get<WorkspaceInfo>('/api/workspace');
  }

  runLeafPlan(path: string, projectRoot?: string): Observable<{ run: { id: string } }> {
    return this.http.post<{ run: { id: string } }>('/api/plans/run', { path, projectRoot });
  }

  stopLeafPlan(path: string, projectRoot?: string): Observable<{ ok: true }> {
    return this.http.post<{ ok: true }>('/api/plans/stop', { path, projectRoot });
  }

  fetchLeafPlanRun(path: string, projectRoot?: string): Observable<{ activeRun: PlanActiveRun | null; activityDiscoveryError?: string }> {
    const params: Record<string, string> = { path };
    if (projectRoot) params['projectRoot'] = projectRoot;
    return this.http.get<{ activeRun: PlanActiveRun | null; activityDiscoveryError?: string }>('/api/plans/run', { params });
  }

  fetchRoots(): Observable<Root[]> {
    return this.http.get<Root[]>('/api/roots');
  }

  fetchListing(root: string, path: string, workspaceRoot?: string, projectRoot?: string): Observable<Listing> {
    const params: Record<string, string> = { root, path };
    if (workspaceRoot) {
      params['workspaceRoot'] = workspaceRoot;
    }
    if (projectRoot) {
      params['projectRoot'] = projectRoot;
    }
    return this.http.get<Listing>('/api/list', { params });
  }

  fetchFile(
    root: string,
    filePath: string,
    offset = 0,
    workspaceRoot?: string,
    projectRoot?: string,
  ): Observable<FileChunk> {
    const params: Record<string, string> = { root, path: filePath, offset: offset.toString() };
    if (workspaceRoot) {
      params['workspaceRoot'] = workspaceRoot;
    }
    if (projectRoot) {
      params['projectRoot'] = projectRoot;
    }
    return this.http.get<FileChunk>('/api/file', { params }).pipe(
      catchError((error: HttpErrorResponse) => {
        const structuredError = this.parseStructuredError(error, filePath);
        return throwError(() => structuredError);
      })
    );
  }

  fetchTemplate(name: TemplateName, projectRoot?: string): Observable<Template> {
    const params: Record<string, string> = { name };
    if (projectRoot) {
      params['projectRoot'] = projectRoot;
    }
    return this.http.get<Template>('/api/template', { params });
  }

  fetchMetricsSummary(): Observable<MetricsSummary> {
    return this.http.get<MetricsSummary>('/api/metrics/summary');
  }

  fetchMetricsInsightsSummary(
    filters?: MetricsQueryFilters,
    options?: ApiRequestOptions,
  ): Observable<MetricsInsightsSummary> {
    return this.withAbort(
      this.http.get<MetricsInsightsSummary>('/api/metrics/insights-summary', {
        params: this.buildMetricsParams(filters),
      }),
      options?.signal,
    );
  }

  fetchMetricsBreakdown(
    filters?: MetricsQueryFilters,
    options?: ApiRequestOptions,
  ): Observable<MetricsBreakdownResponse> {
    return this.withAbort(
      this.http.get<MetricsBreakdownResponse>('/api/metrics/breakdown', {
        params: this.buildMetricsParams(filters),
      }),
      options?.signal,
    );
  }

  fetchMetricsDetail(
    planKey: string,
    workspaceRoot?: string,
    options?: ApiRequestOptions,
  ): Observable<MetricsDetailResponse> {
    const params: Record<string, string> = {};
    if (workspaceRoot) {
      params['workspaceRoot'] = workspaceRoot;
    }
    return this.withAbort(
      this.http.get<MetricsDetailResponse>(`/api/metrics/detail/${encodeURIComponent(planKey)}`, {
        params,
      }),
      options?.signal,
    );
  }

  private buildMetricsParams(filters?: MetricsQueryFilters): Record<string, string> {
    const params: Record<string, string> = {};
    if (!filters) {
      return params;
    }
    if (filters.workspaceRoot) {
      params['workspaceRoot'] = filters.workspaceRoot;
    }
    if (filters.kind && filters.kind !== 'all') {
      params['kind'] = filters.kind;
    }
    if (filters.runtime && filters.runtime !== 'all') {
      params['runtime'] = filters.runtime;
    }
    if (filters.model && filters.model !== 'all') {
      params['model'] = filters.model;
    }
    if (filters.dateFrom) {
      params['dateFrom'] = filters.dateFrom;
    }
    if (filters.dateTo) {
      params['dateTo'] = filters.dateTo;
    }
    if (filters.offset !== undefined) {
      params['offset'] = String(filters.offset);
    }
    if (filters.limit !== undefined) {
      params['limit'] = String(filters.limit);
    }
    if (filters.sortBy) {
      params['sortBy'] = filters.sortBy;
    }
    if (filters.sortDir) {
      params['sortDir'] = filters.sortDir;
    }
    return params;
  }

  fetchSavings(
    filters?: {
      workspaceRoot?: string;
      runtime?: string;
      model?: string;
      plan?: string;
    },
    options?: ApiRequestOptions,
  ): Observable<SavingsReport> {
    const params: Record<string, string> = {};
    if (filters?.workspaceRoot) {
      params['workspaceRoot'] = filters.workspaceRoot;
    }
    if (filters?.runtime) {
      params['runtime'] = filters.runtime;
    }
    if (filters?.model) {
      params['model'] = filters.model;
    }
    if (filters?.plan) {
      params['plan'] = filters.plan;
    }
    return this.withAbort(this.http.get<SavingsReport>('/api/benchmarks', { params }), options?.signal);
  }

  fetchDiscoverReport(planKey: string, workspaceRoot?: string): Observable<DiscoverReportResponse> {
    const params: Record<string, string> = {};
    if (workspaceRoot) {
      params['workspaceRoot'] = workspaceRoot;
    }
    return this.http.get<DiscoverReportResponse>(`/api/metrics/discover/${encodeURIComponent(planKey)}`, {
      params,
    });
  }

  fetchWorkspaces(): Observable<WorkspaceRegistry[]> {
    return this.http.get<WorkspaceRegistry[]>('/api/workspaces');
  }

  fetchRalphFrameworkProjectRoot(): Observable<RalphFrameworkRootResponse> {
    return this.http.get<RalphFrameworkRootResponse>('/api/ralph-framework-root');
  }

  fetchDashboardDocsProjectRoot(): Observable<RalphFrameworkRootResponse> {
    return this.http.get<RalphFrameworkRootResponse>('/api/dashboard-docs-root');
  }

  fetchGraphRuns(workspaceRoot?: string): Observable<GraphRunsResponse> {
    const params: Record<string, string> = {};
    if (workspaceRoot) {
      params['workspaceRoot'] = workspaceRoot;
    }
    return this.http.get<GraphRunsResponse>('/api/graph-runs', { params });
  }

  fetchGraphRunDetail(namespace: string, runId: string, workspaceRoot?: string): Observable<GraphRunDetail> {
    const params: Record<string, string> = {};
    if (workspaceRoot) {
      params['workspaceRoot'] = workspaceRoot;
    }
    return this.http.get<GraphRunDetail>(
      `/api/graph-runs/${encodeURIComponent(namespace)}/${encodeURIComponent(runId)}`,
      { params },
    );
  }

  fetchWorkflowStageLogs(runId: string, stageId: string, attempt: number, workspaceRoot?: string): Observable<WorkflowStageLogResponse> {
    const params: Record<string, string> = { attempt: String(attempt) };
    if (workspaceRoot) params['workspaceRoot'] = workspaceRoot;
    return this.http.get<WorkflowStageLogResponse>(
      `/api/workflow-runs/${encodeURIComponent(runId)}/stages/${encodeURIComponent(stageId)}/logs`,
      { params },
    );
  }

  fetchResourceFile(identity: ResourceIdentity, offset = 0): Observable<FileChunk> {
    const encodedIdentity = ResourceIdentityCodec.encode(identity);
    const params: Record<string, string> = {
      resourceId: encodedIdentity,
      offset: offset.toString()
    };
    return this.http.get<FileChunk>('/api/resource/file', { params }).pipe(
      catchError((error: HttpErrorResponse) => {
        const structuredError = this.parseStructuredError(error, identity.path, identity);
        return throwError(() => structuredError);
      })
    );
  }

  fetchResourceListing(identity: ResourceIdentity): Observable<Listing> {
    const encodedIdentity = ResourceIdentityCodec.encode(identity);
    const params: Record<string, string> = { resourceId: encodedIdentity };
    return this.http.get<Listing>('/api/resource/list', { params });
  }

  fetchPlanIndex(
    filters?: {
      search?: string;
      status?: 'active' | 'completed' | 'waiting';
      type?: 'leaf' | 'generated-control' | 'supplied' | 'workflow-derived';
      projectRoot?: string;
      allProjects?: boolean;
      cursor?: string;
      pageSize?: number;
    },
    options?: ApiRequestOptions,
  ): Observable<PlanInventoryResponse> {
    const params: Record<string, string> = {};
    if (filters?.search) {
      params['search'] = filters.search;
    }
    if (filters?.status) {
      params['status'] = filters.status;
    }
    if (filters?.type) {
      params['type'] = filters.type;
    }
    if (filters?.projectRoot) {
      params['projectRoot'] = filters.projectRoot;
    }
    if (filters?.allProjects) {
      params['allProjects'] = 'true';
    }
    if (filters?.cursor) {
      params['cursor'] = filters.cursor;
    }
    if (filters?.pageSize) {
      params['pageSize'] = filters.pageSize.toString();
    }
    return this.withAbort(
      this.http.get<PlanInventoryResponse>('/api/plans/index', { params }),
      options?.signal,
    );
  }

  private parseStructuredError(error: HttpErrorResponse, requestedPath: string, identity?: ResourceIdentity): ResourceError {
    // Check if error response is structured
    if (error.error && typeof error.error === 'object' && 'code' in error.error) {
      const errorResponse = error.error as Partial<StructuredErrorResponse>;
      return {
        code: (errorResponse.code as ResourceError['code']) || 'UNKNOWN',
        message: errorResponse.message || error.statusText,
        requestedIdentity: identity,
        resolvedPath: errorResponse.resolvedPath,
        title: errorResponse.title || 'Error',
        explanation: errorResponse.explanation || error.statusText,
        recoverable: errorResponse.recoverable ?? true,
        suggestedActions: (errorResponse.suggestedActions || ['RETRY', 'RETURN_TO_PLANS']) as ResourceError['suggestedActions'],
      };
    }

    // Fall back to creating error from HTTP status
    return ResourceErrorBuilder.fromHttpError(error.status, requestedPath, identity);
  }
}
