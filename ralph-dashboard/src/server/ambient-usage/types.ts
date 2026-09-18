export type AmbientProviderId = 'claude_code' | 'codex' | 'antigravity';

export type AmbientProviderStatus = 'available' | 'not_installed' | 'no_data' | 'error';

export interface AmbientRateLimitWindow {
  id: string;
  label: string;
  used_percent: number;
  resets_at: string | null;
  resets_in_seconds: number | null;
}

export interface AmbientModelBreakdownRow {
  model: string;
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_creation_input_tokens: number;
  total_tokens: number;
  sessions: number;
}

export interface AmbientTokenHeadline {
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_creation_input_tokens: number;
  total_tokens: number;
  session_count: number;
}

export interface AmbientProviderReport {
  id: AmbientProviderId;
  label: string;
  status: AmbientProviderStatus;
  message?: string;
  truncated?: boolean;
  quota_fetched_at?: string | null;
  rate_limits: AmbientRateLimitWindow[];
  tokens: AmbientTokenHeadline;
  model_breakdown: AmbientModelBreakdownRow[];
  updated_at: string;
}

export interface AmbientUsageDateScope {
  from: string | null;
  to: string | null;
  label: string;
}

export interface AmbientUsageResponse {
  enabled: boolean;
  scope: 'machine_local';
  date_scope: AmbientUsageDateScope;
  providers: AmbientProviderReport[];
}

export interface AmbientUsageQuery {
  dateFrom?: string;
  dateTo?: string;
}

export interface AmbientCollectorPaths {
  homeDir: string;
  claudeDir: string;
  claudeJsonPath: string;
  codexSessionsDir: string;
}
