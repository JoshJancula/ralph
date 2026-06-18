import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';

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

@Injectable({
  providedIn: 'root',
})
export class ApiService {
  private readonly http = inject(HttpClient);

  fetchWorkspace(): Observable<WorkspaceInfo> {
    return this.http.get<WorkspaceInfo>('/api/workspace');
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
    return this.http.get<FileChunk>('/api/file', { params });
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
}
