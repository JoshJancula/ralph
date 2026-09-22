import { collectAntigravityAmbientUsage, type AgyUsageRunner } from './antigravity';
import { collectClaudeAmbientUsage, type ClaudeAmbientUsageOptions } from './claude';
import { collectCodexAmbientUsage } from './codex';
import { buildAmbientDateScope } from './date-scope';
import { resolveAmbientCollectorPaths } from './paths';
import type { AmbientUsageQuery, AmbientUsageResponse } from './types';

interface CacheEntry {
  key: string;
  expiresAt: number;
  response: AmbientUsageResponse;
}

let cache: CacheEntry | null = null;

function ambientUsageEnabled(): boolean {
  const raw = process.env['RALPH_DASHBOARD_AMBIENT_USAGE']?.trim().toLowerCase();
  return raw !== '0' && raw !== 'false' && raw !== 'no' && raw !== 'off';
}

function cacheTtlMs(): number {
  const raw = process.env['RALPH_DASHBOARD_AMBIENT_USAGE_TTL_MS']?.trim();
  if (raw) {
    const n = Number(raw);
    if (Number.isFinite(n) && n >= 0) {
      return n;
    }
  }
  return 60_000;
}

function cacheKey(query: AmbientUsageQuery, pathsKey: string): string {
  return JSON.stringify({
    dateFrom: query.dateFrom ?? '',
    dateTo: query.dateTo ?? '',
    pathsKey,
  });
}

export async function collectAmbientUsage(
  query: AmbientUsageQuery,
  options?: {
    homeDir?: string;
    bypassCache?: boolean;
    claude?: ClaudeAmbientUsageOptions;
    antigravity?: { binary?: string | null; runner?: AgyUsageRunner };
  },
): Promise<AmbientUsageResponse> {
  const date_scope = buildAmbientDateScope(query);
  if (!ambientUsageEnabled()) {
    return {
      enabled: false,
      scope: 'machine_local',
      date_scope,
      providers: [],
    };
  }

  const paths = resolveAmbientCollectorPaths(options?.homeDir);
  const pathsKey = `${paths.claudeDir}|${paths.claudeJsonPath}|${paths.codexSessionsDir}|agy`;
  const key = cacheKey(query, pathsKey);
  const ttl = cacheTtlMs();
  const now = Date.now();
  if (!options?.bypassCache && cache && cache.expiresAt > now && cache.key === key) {
    return cache.response;
  }

  const [claude, codex, antigravity] = await Promise.all([
    collectClaudeAmbientUsage(paths, date_scope, query, options?.claude),
    collectCodexAmbientUsage(paths, date_scope, query),
    collectAntigravityAmbientUsage(date_scope, query, options?.antigravity),
  ]);

  const response: AmbientUsageResponse = {
    enabled: true,
    scope: 'machine_local',
    date_scope,
    providers: [claude, codex, antigravity],
  };

  cache = { key, expiresAt: now + ttl, response };
  return response;
}

export function clearAmbientUsageCache(): void {
  cache = null;
}
