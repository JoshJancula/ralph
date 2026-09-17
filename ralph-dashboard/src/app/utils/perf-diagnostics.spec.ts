import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';
import {
  PERF_BUDGETS_MS,
  markInventoryUsable,
  markPerf,
  measurePerf,
  setPerfDiagnosticsEnabled,
  setPerfDiagnosticsSink,
} from './perf-diagnostics';

describe('perf-diagnostics', () => {
  beforeEach(() => {
    setPerfDiagnosticsEnabled(true);
    setPerfDiagnosticsSink(null);
    performance.clearMarks?.();
    performance.clearMeasures?.();
  });

  afterEach(() => {
    setPerfDiagnosticsEnabled(false);
    setPerfDiagnosticsSink(null);
  });

  it('exposes budgets that keep primary inventory ahead of secondary metrics', () => {
    expect(PERF_BUDGETS_MS.firstUsableInventoryMs).toBeLessThanOrEqual(2000);
    expect(PERF_BUDGETS_MS.secondaryMetricsMs).toBeGreaterThan(PERF_BUDGETS_MS.firstUsableInventoryMs);
    expect(PERF_BUDGETS_MS.interactionAfterSwitchMs).toBeLessThanOrEqual(500);
  });

  it('measures first usable inventory without capturing paths', () => {
    const marks = new Map<string, number>();
    const measures: Array<{ name: string; duration: number }> = [];
    const perf = {
      mark: (name: string) => {
        marks.set(name, marks.size + 1);
      },
      measure: (name: string, start: string, end: string) => {
        if (!marks.has(start) || !marks.has(end)) {
          throw new Error('missing mark');
        }
        measures.push({ name, duration: 3 });
      },
      getEntriesByName: (name: string) => measures.filter((m) => m.name === name),
      clearMeasures: () => {
        measures.length = 0;
      },
      clearMarks: () => marks.clear(),
    };
    Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

    const sink = vi.fn();
    setPerfDiagnosticsSink(sink);
    markPerf('ralph-nav-start', { section: 'plans' });
    markInventoryUsable('plans');
    expect(sink).toHaveBeenCalled();
    const arg = sink.mock.calls[0][0];
    expect(arg.section).toBe('plans');
    expect(arg.name).toBe('ralph-first-usable-inventory');
    expect(JSON.stringify(arg)).not.toMatch(/\.ralph-workspace|\/Users\//);
  });

  it('no-ops when diagnostics are disabled', () => {
    setPerfDiagnosticsEnabled(false);
    const sink = vi.fn();
    setPerfDiagnosticsSink(sink);
    markPerf('ralph-nav-start');
    expect(measurePerf('x', 'ralph-nav-start', 'ralph-nav-usable', 'plans')).toBeNull();
    expect(sink).not.toHaveBeenCalled();
  });
});
