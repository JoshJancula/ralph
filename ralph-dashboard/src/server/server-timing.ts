import type { Response } from 'express';

/**
 * Privacy-safe Server-Timing helpers for index / read-model generation.
 * Durations only — no paths, plan bodies, or workspace roots.
 */

export interface TimingMetric {
  readonly name: string;
  readonly durationMs: number;
  readonly description?: string;
}

export function formatServerTiming(metrics: readonly TimingMetric[]): string {
  return metrics
    .map((metric) => {
      const desc = metric.description ? `;desc="${metric.description.replace(/"/g, '')}"` : '';
      return `${metric.name};dur=${Math.max(0, Math.round(metric.durationMs))}${desc}`;
    })
    .join(', ');
}

export function appendServerTiming(res: Response, metrics: readonly TimingMetric[]): void {
  if (metrics.length === 0) {
    return;
  }
  const formatted = formatServerTiming(metrics);
  const existing = res.getHeader('Server-Timing');
  if (typeof existing === 'string' && existing.length > 0) {
    res.setHeader('Server-Timing', `${existing}, ${formatted}`);
    return;
  }
  res.setHeader('Server-Timing', formatted);
}

export async function withServerTiming<T>(
  res: Response,
  name: string,
  description: string,
  work: () => Promise<T>,
): Promise<T> {
  const started = performance.now();
  try {
    return await work();
  } finally {
    appendServerTiming(res, [
      {
        name,
        durationMs: performance.now() - started,
        description,
      },
    ]);
  }
}
