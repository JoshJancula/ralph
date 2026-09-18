import { existsSync } from 'node:fs';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';

import { timestampInDateScope } from './date-scope';
import { forEachJsonlLine } from './jsonl';
import { buildRateWindow, sortRateLimits } from './rate-limits';
import type {
  AmbientCollectorPaths,
  AmbientModelBreakdownRow,
  AmbientProviderReport,
  AmbientUsageDateScope,
  AmbientUsageQuery,
} from './types';

const MAX_JSONL_FILES = 500;

function toInt(value: unknown): number {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.max(0, Math.floor(value));
  }
  if (typeof value === 'string' && value.trim()) {
    const n = Number(value);
    if (Number.isFinite(n)) {
      return Math.max(0, Math.floor(n));
    }
  }
  return 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

async function collectJsonlPaths(projectsDir: string): Promise<{ paths: string[]; truncated: boolean }> {
  const paths: string[] = [];
  let truncated = false;

  async function walk(dir: string): Promise<void> {
    if (paths.length >= MAX_JSONL_FILES) {
      truncated = true;
      return;
    }
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (paths.length >= MAX_JSONL_FILES) {
        truncated = true;
        return;
      }
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        paths.push(full);
      }
    }
  }

  if (existsSync(projectsDir)) {
    await walk(projectsDir);
  }
  return { paths, truncated };
}

async function readClaudeRateLimits(claudeJsonPath: string): Promise<{
  windows: AmbientProviderReport['rate_limits'];
  quota_fetched_at: string | null;
}> {
  if (!existsSync(claudeJsonPath)) {
    return { windows: [], quota_fetched_at: null };
  }
  try {
    const text = await readFile(claudeJsonPath, 'utf8');
    const parsed = JSON.parse(text) as Record<string, unknown>;
    const cached = parsed['cachedUsageUtilization'];
    if (!isRecord(cached)) {
      return { windows: [], quota_fetched_at: null };
    }
    const fetchedMs = cached['fetchedAtMs'];
    const quota_fetched_at =
      typeof fetchedMs === 'number' && Number.isFinite(fetchedMs)
        ? new Date(fetchedMs).toISOString()
        : null;
    const windows: AmbientProviderReport['rate_limits'] = [];
    const utilization = cached['utilization'];
    if (isRecord(utilization)) {
      const five = utilization['five_hour'];
      if (isRecord(five)) {
        const w = buildRateWindow(
          'five_hour',
          '5h',
          five['utilization'],
          five['resets_at'] ?? five['resetsAt'],
        );
        if (w) {
          windows.push(w);
        }
      }
      const seven = utilization['seven_day'];
      if (isRecord(seven)) {
        const w = buildRateWindow(
          'seven_day',
          'Weekly',
          seven['utilization'],
          seven['resets_at'] ?? seven['resetsAt'],
        );
        if (w) {
          windows.push(w);
        }
      }
    }
    const limits = cached['limits'];
    if (Array.isArray(limits)) {
      for (const entry of limits) {
        if (!isRecord(entry)) {
          continue;
        }
        const kind = String(entry['kind'] ?? '').trim();
        const id =
          kind === 'session'
            ? 'session'
            : kind === 'weekly_all'
              ? 'seven_day'
              : kind || 'limit';
        const label =
          id === 'session' ? 'Session' : id === 'seven_day' ? 'Weekly' : kind || 'Limit';
        const w = buildRateWindow(id, label, entry['percent'], entry['resets_at'] ?? entry['resetsAt']);
        if (w && !windows.some((existing) => existing.id === w.id)) {
          windows.push(w);
        }
      }
    }
    return { windows: sortRateLimits(windows), quota_fetched_at };
  } catch {
    return { windows: [], quota_fetched_at: null };
  }
}

export async function collectClaudeAmbientUsage(
  paths: AmbientCollectorPaths,
  scope: AmbientUsageDateScope,
  _query: AmbientUsageQuery,
): Promise<AmbientProviderReport> {
  const projectsDir = join(paths.claudeDir, 'projects');
  const claudeInstalled = existsSync(paths.claudeDir);
  if (!claudeInstalled) {
    return {
      id: 'claude_code',
      label: 'Claude',
      status: 'not_installed',
      message: 'No Claude Code config directory found on this machine.',
      rate_limits: [],
      tokens: emptyTokens(),
      model_breakdown: [],
      updated_at: new Date().toISOString(),
    };
  }

  const { paths: jsonlPaths, truncated } = await collectJsonlPaths(projectsDir);
  const modelBuckets = new Map<string, AmbientModelBreakdownRow>();
  let input_tokens = 0;
  let output_tokens = 0;
  let cache_read_input_tokens = 0;
  let cache_creation_input_tokens = 0;
  const sessionIds = new Set<string>();

  for (const filePath of jsonlPaths) {
    await forEachJsonlLine(filePath, async (line) => {
      let record: Record<string, unknown>;
      try {
        record = JSON.parse(line) as Record<string, unknown>;
      } catch {
        return;
      }
      if (record['type'] !== 'assistant') {
        return;
      }
      const timestamp = typeof record['timestamp'] === 'string' ? record['timestamp'] : undefined;
      if (!timestampInDateScope(timestamp, scope)) {
        return;
      }
      const message = record['message'];
      if (!isRecord(message)) {
        return;
      }
      const usage = message['usage'];
      if (!isRecord(usage)) {
        return;
      }
      const inTok = toInt(usage['input_tokens']);
      const outTok = toInt(usage['output_tokens']);
      const cacheRead = toInt(usage['cache_read_input_tokens']);
      const cacheCreate = toInt(usage['cache_creation_input_tokens']);
      if (inTok + outTok + cacheRead + cacheCreate === 0) {
        return;
      }
      input_tokens += inTok;
      output_tokens += outTok;
      cache_read_input_tokens += cacheRead;
      cache_creation_input_tokens += cacheCreate;
      const sessionId = typeof record['sessionId'] === 'string' ? record['sessionId'] : filePath;
      sessionIds.add(sessionId);
      const model =
        (typeof message['model'] === 'string' && message['model'].trim()) || '(unspecified)';
      const bucket =
        modelBuckets.get(model) ??
        {
          model,
          input_tokens: 0,
          output_tokens: 0,
          cache_read_input_tokens: 0,
          cache_creation_input_tokens: 0,
          total_tokens: 0,
          sessions: 0,
        };
      bucket.input_tokens += inTok;
      bucket.output_tokens += outTok;
      bucket.cache_read_input_tokens += cacheRead;
      bucket.cache_creation_input_tokens += cacheCreate;
      bucket.total_tokens += inTok + outTok + cacheRead + cacheCreate;
      modelBuckets.set(model, bucket);
    });
  }

  const model_breakdown = Array.from(modelBuckets.values()).sort(
    (a, b) => b.total_tokens - a.total_tokens,
  );
  const { windows, quota_fetched_at } = await readClaudeRateLimits(paths.claudeJsonPath);
  const hasTokens = input_tokens + output_tokens + cache_read_input_tokens + cache_creation_input_tokens > 0;
  const hasQuota = windows.length > 0;

  return {
    id: 'claude_code',
    label: 'Claude',
    status: hasTokens || hasQuota ? 'available' : 'no_data',
    message:
      !hasTokens && !hasQuota
        ? 'No Claude Code transcripts or cached quota found for this scope.'
        : truncated
          ? `Showing the first ${MAX_JSONL_FILES} transcript files; rescan may include more.`
          : undefined,
    truncated,
    quota_fetched_at,
    rate_limits: windows,
    tokens: {
      input_tokens,
      output_tokens,
      cache_read_input_tokens,
      cache_creation_input_tokens,
      total_tokens: input_tokens + output_tokens + cache_read_input_tokens + cache_creation_input_tokens,
      session_count: sessionIds.size,
    },
    model_breakdown,
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
