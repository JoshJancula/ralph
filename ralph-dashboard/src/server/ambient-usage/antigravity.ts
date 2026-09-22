import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

import { resolveRuntimeBinary } from '../ralph-cli';
import { buildRateWindow, sortRateLimits } from './rate-limits';
import type {
  AmbientProviderReport,
  AmbientRateLimitWindow,
  AmbientUsageDateScope,
  AmbientUsageQuery,
} from './types';

const execFileAsync = promisify(execFile);
const USAGE_TIMEOUT_MS = 15_000;
const USAGE_MAX_BUFFER = 1024 * 1024;

export type AgyUsageRunner = (binary: string) => Promise<{ stdout: string; stderr: string }>;

const defaultAgyUsageRunner: AgyUsageRunner = async (binary) => {
  const result = await execFileAsync(binary, ['--print', '/usage', '--output-format', 'json'], {
    timeout: USAGE_TIMEOUT_MS,
    maxBuffer: USAGE_MAX_BUFFER,
    windowsHide: true,
    env: process.env,
  });
  return {
    stdout: String(result.stdout ?? ''),
    stderr: String(result.stderr ?? ''),
  };
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
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

function parseJsonPayload(stdout: string): unknown {
  const trimmed = stdout.trim();
  if (!trimmed) {
    return null;
  }
  try {
    return JSON.parse(trimmed) as unknown;
  } catch {
    const start = trimmed.indexOf('{');
    const end = trimmed.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(trimmed.slice(start, end + 1)) as unknown;
      } catch {
        return null;
      }
    }
    return null;
  }
}

function usedPercentFromRemainingFraction(remaining: unknown): number | null {
  if (typeof remaining !== 'number' || !Number.isFinite(remaining)) {
    return null;
  }
  const clamped = Math.min(1, Math.max(0, remaining));
  return (1 - clamped) * 100;
}

/**
 * Map `agy --print /usage --output-format json` buckets into ambient rate windows.
 * Antigravity reports remaining_fraction (0-1); Ralph stores used_percent (0-100).
 */
export function rateLimitsFromAgyUsagePayload(payload: unknown): AmbientRateLimitWindow[] {
  if (!isRecord(payload)) {
    return [];
  }
  const command = payload['command'];
  if (!isRecord(command)) {
    return [];
  }
  const data = command['data'];
  if (!isRecord(data) || !Array.isArray(data['groups'])) {
    return [];
  }

  const windows: AmbientRateLimitWindow[] = [];
  for (const group of data['groups']) {
    if (!isRecord(group) || !Array.isArray(group['buckets'])) {
      continue;
    }
    const groupName = typeof group['name'] === 'string' && group['name'].trim() ? group['name'].trim() : 'Antigravity';
    for (const bucket of group['buckets']) {
      if (!isRecord(bucket)) {
        continue;
      }
      const usedPercent = usedPercentFromRemainingFraction(bucket['remaining_fraction']);
      if (usedPercent === null) {
        continue;
      }
      const bucketId =
        typeof bucket['id'] === 'string' && bucket['id'].trim()
          ? bucket['id'].trim()
          : `${groupName}-${String(bucket['window'] ?? 'limit')}`;
      const bucketName =
        typeof bucket['name'] === 'string' && bucket['name'].trim() ? bucket['name'].trim() : 'Limit';
      const label = `${groupName} · ${bucketName.replace(/\s+Remaining$/i, '').trim() || 'Limit'}`;
      const w = buildRateWindow(bucketId, label, usedPercent, bucket['reset_time'] ?? bucket['resets_at']);
      if (w && !windows.some((existing) => existing.id === w.id)) {
        windows.push(w);
      }
    }
  }
  return sortRateLimits(windows);
}

export async function collectAntigravityAmbientUsage(
  _scope: AmbientUsageDateScope,
  _query: AmbientUsageQuery,
  options?: { runner?: AgyUsageRunner; binary?: string | null },
): Promise<AmbientProviderReport> {
  const binary = options?.binary !== undefined ? options.binary : resolveRuntimeBinary('antigravity');
  if (!binary) {
    return {
      id: 'antigravity',
      label: 'Antigravity',
      status: 'not_installed',
      message: 'Antigravity CLI (agy) not found on PATH.',
      rate_limits: [],
      tokens: emptyTokens(),
      model_breakdown: [],
      updated_at: new Date().toISOString(),
    };
  }

  const runner = options?.runner ?? defaultAgyUsageRunner;
  try {
    const { stdout, stderr } = await runner(binary);
    const combined = `${stdout}\n${stderr}`;
    if (/not signed in|sign in|select login method|authentication required/iu.test(combined)) {
      return {
        id: 'antigravity',
        label: 'Antigravity',
        status: 'no_data',
        message: 'Antigravity is installed but not signed in.',
        rate_limits: [],
        tokens: emptyTokens(),
        model_breakdown: [],
        updated_at: new Date().toISOString(),
      };
    }

    const payload = parseJsonPayload(stdout);
    if (!payload) {
      return {
        id: 'antigravity',
        label: 'Antigravity',
        status: 'error',
        message: 'Antigravity usage command returned non-JSON output.',
        rate_limits: [],
        tokens: emptyTokens(),
        model_breakdown: [],
        updated_at: new Date().toISOString(),
      };
    }

    if (isRecord(payload) && typeof payload['status'] === 'string' && payload['status'] !== 'SUCCESS') {
      return {
        id: 'antigravity',
        label: 'Antigravity',
        status: 'error',
        message: `Antigravity usage status: ${payload['status']}`,
        rate_limits: [],
        tokens: emptyTokens(),
        model_breakdown: [],
        updated_at: new Date().toISOString(),
      };
    }

    const rate_limits = rateLimitsFromAgyUsagePayload(payload);
    return {
      id: 'antigravity',
      label: 'Antigravity',
      status: rate_limits.length > 0 ? 'available' : 'no_data',
      message: rate_limits.length > 0 ? undefined : 'No Antigravity quota windows returned.',
      rate_limits,
      tokens: emptyTokens(),
      model_breakdown: [],
      updated_at: new Date().toISOString(),
      quota_fetched_at: new Date().toISOString(),
    };
  } catch (error: unknown) {
    const failure = error as { stdout?: string; stderr?: string; code?: string | number; message?: string };
    const output = `${failure.stdout ?? ''}\n${failure.stderr ?? ''}\n${failure.message ?? ''}`;
    if (/not signed in|sign in|select login method|authentication required/iu.test(output)) {
      return {
        id: 'antigravity',
        label: 'Antigravity',
        status: 'no_data',
        message: 'Antigravity is installed but not signed in.',
        rate_limits: [],
        tokens: emptyTokens(),
        model_breakdown: [],
        updated_at: new Date().toISOString(),
      };
    }
    return {
      id: 'antigravity',
      label: 'Antigravity',
      status: 'error',
      message: failure.code === 'ETIMEDOUT' ? 'Antigravity usage check timed out.' : 'Failed to read Antigravity usage.',
      rate_limits: [],
      tokens: emptyTokens(),
      model_breakdown: [],
      updated_at: new Date().toISOString(),
    };
  }
}
