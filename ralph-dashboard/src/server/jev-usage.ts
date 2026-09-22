import { promises as fs } from 'node:fs';
import { dirname, join } from 'node:path';

/**
 * Jev (TypeSafe AI) is an HTTP adapter, not a CLI runtime, so its usage is not
 * part of the runtime token/cache metrics. The transport appends one line per
 * successful call to <workspace_root>/jev/usage.jsonl; this reads and sums them.
 */

const DEFAULT_INPUT_USD_PER_MTOK = 0.042;
const DEFAULT_OUTPUT_USD_PER_MTOK = 0;
const DAY_MS = 24 * 60 * 60 * 1000;

export interface JevUsageQuestionSetRow {
  question_set_id: string;
  calls: number;
  input_tokens: number;
  output_tokens: number;
}

export interface JevUsageResponse {
  /** True only when at least one live Jev call was recorded in scope. */
  enabled: boolean;
  calls: number;
  calls_measured: number;
  calls_unavailable: number;
  input_tokens: number;
  output_tokens: number;
  estimated_usd: number;
  by_question_set: JevUsageQuestionSetRow[];
}

function nonNegInt(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0;
}

function rate(name: string, fallback: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) {
    return fallback;
  }
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function scopeBounds(dateFrom?: string, dateTo?: string): { from: number; to: number } {
  const from = dateFrom ? Date.parse(dateFrom) : NaN;
  let to = dateTo ? Date.parse(dateTo) : NaN;
  // A bare YYYY-MM-DD upper bound means the whole day.
  if (dateTo && /^\d{4}-\d{2}-\d{2}$/.test(dateTo) && Number.isFinite(to)) {
    to += DAY_MS - 1;
  }
  return {
    from: Number.isFinite(from) ? from : Number.NEGATIVE_INFINITY,
    to: Number.isFinite(to) ? to : Number.POSITIVE_INFINITY,
  };
}

export async function collectJevUsage(options: {
  /** Ralph logs roots (<workspace_root>/logs); the Jev state dir is a sibling. */
  logsRoots: string[];
  dateFrom?: string;
  dateTo?: string;
}): Promise<JevUsageResponse> {
  const { from, to } = scopeBounds(options.dateFrom, options.dateTo);
  const bySet = new Map<string, JevUsageQuestionSetRow>();
  let calls = 0;
  let measured = 0;
  let unavailable = 0;
  let inputTokens = 0;
  let outputTokens = 0;

  const seen = new Set<string>();
  for (const logsRoot of options.logsRoots) {
    const file = join(dirname(logsRoot), 'jev', 'usage.jsonl');
    if (seen.has(file)) {
      continue;
    }
    seen.add(file);
    let raw: string;
    try {
      raw = await fs.readFile(file, 'utf8');
    } catch {
      continue;
    }
    for (const line of raw.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) {
        continue;
      }
      let rec: Record<string, unknown>;
      try {
        const parsed: unknown = JSON.parse(trimmed);
        if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
          continue;
        }
        rec = parsed as Record<string, unknown>;
      } catch {
        continue;
      }
      // Offline fixture replays are test traffic, not real spend.
      if (rec['transport'] === 'fixture') {
        continue;
      }
      if (from !== Number.NEGATIVE_INFINITY || to !== Number.POSITIVE_INFINITY) {
        const ts = typeof rec['timestamp'] === 'string' ? Date.parse(rec['timestamp']) : NaN;
        if (!Number.isFinite(ts) || ts < from || ts > to) {
          continue;
        }
      }
      const input = nonNegInt(rec['input_tokens']);
      const output = nonNegInt(rec['output_tokens']);
      calls += 1;
      inputTokens += input;
      outputTokens += output;
      if (rec['usageSource'] === 'measured') {
        measured += 1;
      } else {
        unavailable += 1;
      }
      const id =
        typeof rec['questionSetId'] === 'string' && rec['questionSetId']
          ? rec['questionSetId']
          : '(unnamed)';
      const row = bySet.get(id) ?? { question_set_id: id, calls: 0, input_tokens: 0, output_tokens: 0 };
      row.calls += 1;
      row.input_tokens += input;
      row.output_tokens += output;
      bySet.set(id, row);
    }
  }

  const usd =
    (inputTokens * rate('RALPH_JEV_INPUT_USD_PER_MTOK', DEFAULT_INPUT_USD_PER_MTOK)) / 1_000_000 +
    (outputTokens * rate('RALPH_JEV_OUTPUT_USD_PER_MTOK', DEFAULT_OUTPUT_USD_PER_MTOK)) / 1_000_000;

  return {
    enabled: calls > 0,
    calls,
    calls_measured: measured,
    calls_unavailable: unavailable,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    estimated_usd: Math.round(usd * 1_000_000) / 1_000_000,
    by_question_set: [...bySet.values()].sort((a, b) => b.calls - a.calls),
  };
}
