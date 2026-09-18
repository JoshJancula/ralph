import { existsSync } from 'node:fs';
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';

import { timestampInDateScope } from './date-scope';
import { forEachJsonlLine } from './jsonl';
import { buildRateWindow, sortRateLimits } from './rate-limits';
import type {
  AmbientCollectorPaths,
  AmbientProviderReport,
  AmbientRateLimitWindow,
  AmbientUsageDateScope,
  AmbientUsageQuery,
} from './types';

const MAX_JSONL_FILES = 500;
/** Weekly windows are ~7d; Codex often emits 10079/10080. */
const WEEKLY_WINDOW_MINUTES_MIN = 7 * 24 * 60 - 120;
/** 5h windows are ~300 minutes. */
const FIVE_HOUR_WINDOW_MINUTES_MIN = 60;
const FIVE_HOUR_WINDOW_MINUTES_MAX = 6 * 60;

function toInt(value: unknown): number {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.max(0, Math.floor(value));
  }
  return 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Collect session JSONL paths, newest first.
 * Codex layouts are `sessions/YYYY/MM/DD/rollout-*.jsonl`; reverse path order
 * prefers recent days without stating every file.
 */
async function collectJsonlPaths(sessionsDir: string): Promise<{ paths: string[]; truncated: boolean }> {
  const paths: string[] = [];

  async function walk(dir: string): Promise<void> {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        paths.push(full);
      }
    }
  }

  if (existsSync(sessionsDir)) {
    await walk(sessionsDir);
  }
  paths.sort((a, b) => (a < b ? 1 : a > b ? -1 : 0));
  if (paths.length > MAX_JSONL_FILES) {
    return { paths: paths.slice(0, MAX_JSONL_FILES), truncated: true };
  }
  return { paths, truncated: false };
}

function mapCodexUsage(usage: Record<string, unknown>): {
  input: number;
  output: number;
  cache_read: number;
} {
  const input = toInt(usage['input_tokens']);
  const cached = toInt(usage['cached_input_tokens']);
  const output = toInt(usage['output_tokens']) + toInt(usage['reasoning_output_tokens']);
  return { input, output, cache_read: cached };
}

function windowMinutes(window: Record<string, unknown>): number | null {
  const raw = window['window_minutes'];
  return typeof raw === 'number' && Number.isFinite(raw) ? raw : null;
}

/**
 * Map Codex primary/secondary windows by duration.
 * Current Plus payloads put the weekly meter on primary (secondary null);
 * older payloads used primary≈5h and secondary≈weekly.
 */
export function rateLimitsFromCodexPayload(payload: Record<string, unknown>): AmbientRateLimitWindow[] {
  const rateLimits = payload['rate_limits'];
  if (!isRecord(rateLimits)) {
    return [];
  }
  const windows: AmbientRateLimitWindow[] = [];
  for (const key of ['primary', 'secondary'] as const) {
    const raw = rateLimits[key];
    if (!isRecord(raw)) {
      continue;
    }
    const minutes = windowMinutes(raw);
    if (minutes == null) {
      continue;
    }
    const resetsAt = raw['resets_at'] ?? raw['resetsAt'];
    if (minutes >= WEEKLY_WINDOW_MINUTES_MIN) {
      const w = buildRateWindow('weekly', 'Weekly', raw['used_percent'], resetsAt);
      if (w && !windows.some((existing) => existing.id === 'weekly')) {
        windows.push(w);
      }
    } else if (minutes >= FIVE_HOUR_WINDOW_MINUTES_MIN && minutes <= FIVE_HOUR_WINDOW_MINUTES_MAX) {
      const w = buildRateWindow('five_hour', '5h', raw['used_percent'], resetsAt);
      if (w && !windows.some((existing) => existing.id === 'five_hour')) {
        windows.push(w);
      }
    }
  }
  return sortRateLimits(windows);
}

export async function collectCodexAmbientUsage(
  paths: AmbientCollectorPaths,
  scope: AmbientUsageDateScope,
  _query: AmbientUsageQuery,
): Promise<AmbientProviderReport> {
  const sessionsDir = paths.codexSessionsDir;
  if (!existsSync(sessionsDir)) {
    return {
      id: 'codex',
      label: 'Codex',
      status: 'not_installed',
      message: 'No Codex sessions directory found on this machine.',
      rate_limits: [],
      tokens: emptyTokens(),
      model_breakdown: [],
      updated_at: new Date().toISOString(),
    };
  }

  const { paths: jsonlPaths, truncated } = await collectJsonlPaths(sessionsDir);
  let input_tokens = 0;
  let output_tokens = 0;
  let cache_read_input_tokens = 0;
  let sessionsWithUsage = 0;
  let latestRateLimits: AmbientRateLimitWindow[] = [];
  let latestRateTs = 0;

  for (const filePath of jsonlPaths) {
    let sessionInput = 0;
    let sessionOutput = 0;
    let sessionCache = 0;
    let sessionInScope = false;

    await forEachJsonlLine(filePath, async (line) => {
      let record: Record<string, unknown>;
      try {
        record = JSON.parse(line) as Record<string, unknown>;
      } catch {
        return;
      }
      const timestamp = typeof record['timestamp'] === 'string' ? record['timestamp'] : undefined;

      if (record['type'] === 'session_meta') {
        return;
      }

      if (record['type'] !== 'event_msg') {
        return;
      }
      const payload = record['payload'];
      if (!isRecord(payload) || payload['type'] !== 'token_count') {
        return;
      }

      // Account quota is live machine state — take the newest non-null snapshot
      // even when the transcript date filter excludes this event.
      if (isRecord(payload['rate_limits'])) {
        const ts = timestamp ? Date.parse(timestamp) : 0;
        if (ts >= latestRateTs) {
          const windows = rateLimitsFromCodexPayload(payload);
          if (windows.length > 0) {
            latestRateTs = ts;
            latestRateLimits = windows;
          }
        }
      }

      if (!timestampInDateScope(timestamp, scope)) {
        return;
      }
      sessionInScope = true;
      const info = payload['info'];
      if (!isRecord(info)) {
        return;
      }
      const total = info['total_token_usage'];
      if (isRecord(total)) {
        const mapped = mapCodexUsage(total);
        sessionInput = mapped.input;
        sessionOutput = mapped.output;
        sessionCache = mapped.cache_read;
      }
    });

    if (sessionInScope && sessionInput + sessionOutput + sessionCache > 0) {
      sessionsWithUsage += 1;
      input_tokens += sessionInput;
      output_tokens += sessionOutput;
      cache_read_input_tokens += sessionCache;
    }
  }

  const hasTokens = input_tokens + output_tokens + cache_read_input_tokens > 0;
  const hasQuota = latestRateLimits.length > 0;

  return {
    id: 'codex',
    label: 'Codex',
    status: hasTokens || hasQuota ? 'available' : 'no_data',
    message:
      !hasTokens && !hasQuota
        ? 'No Codex session usage found for this scope.'
        : truncated
          ? `Showing the first ${MAX_JSONL_FILES} newest session files; rescan may include more.`
          : undefined,
    truncated,
    rate_limits: latestRateLimits,
    tokens: {
      input_tokens,
      output_tokens,
      cache_read_input_tokens,
      cache_creation_input_tokens: 0,
      total_tokens: input_tokens + output_tokens + cache_read_input_tokens,
      session_count: sessionsWithUsage,
    },
    model_breakdown: [],
    updated_at: new Date().toISOString(),
  };
}

function emptyTokens(): AmbientProviderReport['tokens'] {
  return {
    input_tokens: 0,
    output_tokens: 0,
    cache_read_input_tokens: 0,
    cache_creation_input_tokens: 0,
    total_tokens: 0,
    session_count: 0,
  };
}
