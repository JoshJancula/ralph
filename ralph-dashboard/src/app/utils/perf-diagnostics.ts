/**
 * Privacy-safe client timing around navigation and first usable inventory.
 * Diagnostics are development-only (isDevMode) and never include file contents,
 * workspace paths, or plan bodies — only route section names and durations.
 */

export const PERF_BUDGETS_MS = {
  /** Primary inventory (plans/runs/workflows/home list) interactive after project switch. */
  firstUsableInventoryMs: 2000,
  /** Optional metrics / secondary panels may trail primary inventory. */
  secondaryMetricsMs: 5000,
  /** Interaction (toolbar/filters) remains usable while secondary data loads. */
  interactionAfterSwitchMs: 500,
} as const;

export type PerfMarkName =
  | 'ralph-nav-start'
  | 'ralph-nav-usable'
  | 'ralph-inventory-usable'
  | 'ralph-secondary-ready';

export interface PerfMeasure {
  readonly name: string;
  readonly durationMs: number;
  readonly section: string;
}

type PerfSink = (measure: PerfMeasure) => void;

let sink: PerfSink | null = null;
let enabled = false;

export function setPerfDiagnosticsEnabled(value: boolean): void {
  enabled = value;
}

export function setPerfDiagnosticsSink(next: PerfSink | null): void {
  sink = next;
}

function performanceApi(): Performance | null {
  if (typeof globalThis === 'undefined') {
    return null;
  }
  const perf = (globalThis as { performance?: Performance }).performance;
  return perf ?? null;
}

export function markPerf(name: PerfMarkName, detail?: { section?: string }): void {
  if (!enabled) {
    return;
  }
  const perf = performanceApi();
  if (!perf?.mark) {
    return;
  }
  try {
    perf.mark(name, detail?.section ? { detail: { section: detail.section } } : undefined);
  } catch {
    // Older Performance implementations reject mark options; fall back.
    try {
      perf.mark(name);
    } catch {
      // Ignore mark failures in constrained test environments.
    }
  }
}

export function measurePerf(
  name: string,
  startMark: PerfMarkName,
  endMark: PerfMarkName,
  section: string,
): PerfMeasure | null {
  if (!enabled) {
    return null;
  }
  const perf = performanceApi();
  if (!perf?.measure || !perf.getEntriesByName) {
    return null;
  }
  try {
    // Clear prior measure of the same name to avoid duplicates.
    perf.clearMeasures?.(name);
    perf.measure(name, startMark, endMark);
    const entries = perf.getEntriesByName(name, 'measure');
    const last = entries[entries.length - 1];
    if (!last) {
      return null;
    }
    const measure: PerfMeasure = {
      name,
      durationMs: Math.round(last.duration),
      section,
    };
    sink?.(measure);
    if (typeof console !== 'undefined' && typeof console.debug === 'function') {
      console.debug(`[ralph-perf] ${section} ${name}=${measure.durationMs}ms`);
    }
    return measure;
  } catch {
    return null;
  }
}

export function markInventoryUsable(section: string): void {
  markPerf('ralph-inventory-usable', { section });
  measurePerf('ralph-first-usable-inventory', 'ralph-nav-start', 'ralph-inventory-usable', section);
}

export function markSecondaryReady(section: string): void {
  markPerf('ralph-secondary-ready', { section });
  measurePerf('ralph-secondary-ready', 'ralph-nav-start', 'ralph-secondary-ready', section);
}
