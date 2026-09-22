import { jest } from '@jest/globals';
import {
  PERF_BUDGETS_MS,
  markInventoryUsable,
  markPerf,
  markSecondaryReady,
  measurePerf,
  setPerfDiagnosticsEnabled,
  setPerfDiagnosticsSink,
} from './perf-diagnostics';

describe('perf-diagnostics', () => {
  beforeEach(() => {
    setPerfDiagnosticsEnabled(true);
    setPerfDiagnosticsSink(null);
  });

  afterEach(() => {
    setPerfDiagnosticsEnabled(false);
    setPerfDiagnosticsSink(null);
  });

  it('exposes budgets that keep primary inventory ahead of secondary metrics', () => {
    expect(PERF_BUDGETS_MS.firstUsableInventoryMs).toBe(2000);
    expect(PERF_BUDGETS_MS.secondaryMetricsMs).toBe(5000);
    expect(PERF_BUDGETS_MS.interactionAfterSwitchMs).toBe(500);
  });

  describe('markPerf', () => {
    it('records a mark when enabled and performance API is available', () => {
      const markSpy = jest.fn();
      const perf = { mark: markSpy } as unknown as Performance;
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      markPerf('ralph-nav-start', { section: 'plans' });

      expect(markSpy).toHaveBeenCalledTimes(1);
      expect(markSpy).toHaveBeenCalledWith(
        'ralph-nav-start',
        expect.objectContaining({ detail: expect.objectContaining({ section: 'plans' }) }),
      );
    });

    it('falls back to mark without options when detail options are rejected', () => {
      const markSpy = jest.fn().mockImplementationOnce(() => {
        throw new Error('detail not supported');
      });
      const perf = { mark: markSpy } as unknown as Performance;
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      markPerf('ralph-nav-start', { section: 'plans' });

      expect(markSpy).toHaveBeenCalledTimes(2);
      expect(markSpy).toHaveBeenLastCalledWith('ralph-nav-start');
    });

    it('swallows repeated mark failures without throwing', () => {
      const markSpy = jest.fn().mockImplementation(() => {
        throw new Error('always fails');
      });
      const perf = { mark: markSpy } as unknown as Performance;
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      expect(() => markPerf('ralph-nav-start')).not.toThrow();
      expect(markSpy).toHaveBeenCalledTimes(2);
    });

    it('no-ops when diagnostics are disabled', () => {
      const markSpy = jest.fn();
      const perf = { mark: markSpy } as unknown as Performance;
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      setPerfDiagnosticsEnabled(false);
      markPerf('ralph-nav-start');

      expect(markSpy).not.toHaveBeenCalled();
    });

    it('no-ops when performance API is unavailable', () => {
      Object.defineProperty(globalThis, 'performance', { value: undefined, configurable: true });

      expect(() => markPerf('ralph-nav-start')).not.toThrow();
    });

    it('no-ops when globalThis is undefined', () => {
      // Cannot test actual undefined globalThis, but coverage exercises missing perf object branch.
      Object.defineProperty(globalThis, 'performance', { value: {}, configurable: true });

      expect(() => markPerf('ralph-nav-start')).not.toThrow();
    });
  });

  describe('measurePerf', () => {
    function createMockPerformance(overrides: {
      measureError?: boolean;
      noEntries?: boolean;
      missingApi?: boolean;
    } = {}) {
      const marks = new Map<string, number>();
      const measures: Array<{ name: string; duration: number }> = [];
      const clearMeasures = jest.fn(() => {
        measures.length = 0;
      });
      const measure = overrides.measureError
        ? jest.fn(() => {
            throw new Error('measure failed');
          })
        : jest.fn((name: string, start: string, end: string) => {
            if (!marks.has(start) || !marks.has(end)) {
              throw new Error('missing mark');
            }
            measures.push({ name, duration: 3 });
          });
      const getEntriesByName = overrides.noEntries
        ? jest.fn(() => [])
        : jest.fn((name: string) => measures.filter((m) => m.name === name));
      const mark = jest.fn((name: string) => {
        marks.set(name, marks.size + 1);
      });

      const perf: Performance = {
        mark,
        measure,
        getEntriesByName,
        clearMeasures,
        clearMarks: jest.fn(),
      } as unknown as Performance;

      return { perf, measure, clearMeasures };
    }

    it('returns a measure, calls sink, and logs when enabled', () => {
      const { perf, measure } = createMockPerformance();
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      const sink = jest.fn();
      setPerfDiagnosticsSink(sink);
      const debugSpy = jest.spyOn(console, 'debug').mockImplementation(() => {});

      markPerf('ralph-nav-start', { section: 'plans' });
      markPerf('ralph-nav-usable', { section: 'plans' });
      const result = measurePerf(
        'ralph-first-usable-inventory',
        'ralph-nav-start',
        'ralph-nav-usable',
        'plans',
      );

      expect(measure).toHaveBeenCalledWith(
        'ralph-first-usable-inventory',
        'ralph-nav-start',
        'ralph-nav-usable',
      );
      expect(result).toEqual({ name: 'ralph-first-usable-inventory', durationMs: 3, section: 'plans' });
      expect(sink).toHaveBeenCalledWith(result);
      expect(debugSpy).toHaveBeenCalled();

      debugSpy.mockRestore();
    });

    it('clears prior measures of the same name before measuring', () => {
      const { perf, clearMeasures } = createMockPerformance();
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      markPerf('ralph-nav-start', { section: 'plans' });
      markPerf('ralph-nav-usable', { section: 'plans' });
      measurePerf('ralph-first-usable-inventory', 'ralph-nav-start', 'ralph-nav-usable', 'plans');

      expect(clearMeasures).toHaveBeenCalledWith('ralph-first-usable-inventory');
    });

    it('returns null when getEntriesByName yields no entries', () => {
      const { perf } = createMockPerformance({ noEntries: true });
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      markPerf('ralph-nav-start', { section: 'plans' });
      markPerf('ralph-nav-usable', { section: 'plans' });
      const result = measurePerf('x', 'ralph-nav-start', 'ralph-nav-usable', 'plans');

      expect(result).toBeNull();
    });

    it('returns null when diagnostics are disabled', () => {
      const { perf, measure } = createMockPerformance();
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      setPerfDiagnosticsEnabled(false);
      markPerf('ralph-nav-start', { section: 'plans' });
      markPerf('ralph-nav-usable', { section: 'plans' });
      const result = measurePerf('x', 'ralph-nav-start', 'ralph-nav-usable', 'plans');

      expect(result).toBeNull();
      expect(measure).not.toHaveBeenCalled();
    });

    it('returns null when measure API is missing', () => {
      Object.defineProperty(globalThis, 'performance', { value: { getEntriesByName: jest.fn(), mark: jest.fn() }, configurable: true });

      markPerf('ralph-nav-start', { section: 'plans' });
      markPerf('ralph-nav-usable', { section: 'plans' });
      const result = measurePerf('x', 'ralph-nav-start', 'ralph-nav-usable', 'plans');

      expect(result).toBeNull();
    });

    it('returns null when getEntriesByName API is missing', () => {
      Object.defineProperty(globalThis, 'performance', { value: { measure: jest.fn(), mark: jest.fn() }, configurable: true });

      markPerf('ralph-nav-start', { section: 'plans' });
      markPerf('ralph-nav-usable', { section: 'plans' });
      const result = measurePerf('x', 'ralph-nav-start', 'ralph-nav-usable', 'plans');

      expect(result).toBeNull();
    });

    it('swallows measure exceptions and returns null', () => {
      const { perf } = createMockPerformance({ measureError: true });
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      markPerf('ralph-nav-start', { section: 'plans' });
      markPerf('ralph-nav-usable', { section: 'plans' });
      const result = measurePerf('x', 'ralph-nav-start', 'ralph-nav-usable', 'plans');

      expect(result).toBeNull();
    });
  });

  describe('markInventoryUsable', () => {
    it('marks inventory usable and measures first usable inventory', () => {
      const markSpy = jest.fn();
      const measures: Array<{ name: string; duration: number }> = [];
      const perf = {
        mark: markSpy,
        measure: jest.fn((name: string, start: string, end: string) => {
          measures.push({ name, duration: 3 });
        }),
        getEntriesByName: jest.fn((name: string) => measures.filter((m) => m.name === name)),
        clearMeasures: jest.fn(),
        clearMarks: jest.fn(),
      } as unknown as Performance;
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      const sink = jest.fn();
      setPerfDiagnosticsSink(sink);

      markPerf('ralph-nav-start', { section: 'plans' });
      markInventoryUsable('plans');

      expect(markSpy).toHaveBeenCalledWith(
        'ralph-inventory-usable',
        expect.objectContaining({ detail: expect.objectContaining({ section: 'plans' }) }),
      );
      expect(sink).toHaveBeenCalled();
      const arg = sink.mock.calls[0][0];
      expect(arg).toEqual({ name: 'ralph-first-usable-inventory', durationMs: 3, section: 'plans' });
    });

    it('does not leak paths in the measure payload', () => {
      const measures: Array<{ name: string; duration: number }> = [];
      const perf = {
        mark: jest.fn(),
        measure: jest.fn((name: string, _start: string, _end: string) => {
          measures.push({ name, duration: 3 });
        }),
        getEntriesByName: jest.fn((name: string) => measures.filter((m) => m.name === name)),
        clearMeasures: jest.fn(),
        clearMarks: jest.fn(),
      } as unknown as Performance;
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      const sink = jest.fn();
      setPerfDiagnosticsSink(sink);

      markPerf('ralph-nav-start', { section: 'plans' });
      markPerf('ralph-inventory-usable', { section: '/Users/demo/.ralph-workspace/plans' });
      markInventoryUsable('inventory');

      const arg = sink.mock.calls[0][0];
      expect(JSON.stringify(arg)).not.toMatch(/\.ralph-workspace|\/Users\//i);
      expect(arg.section).toBe('inventory');
    });
  });

  describe('markSecondaryReady', () => {
    it('marks secondary ready and measures from nav start', () => {
      const markSpy = jest.fn();
      const measures: Array<{ name: string; duration: number }> = [];
      const perf = {
        mark: markSpy,
        measure: jest.fn((name: string, _start: string, _end: string) => {
          measures.push({ name, duration: 5 });
        }),
        getEntriesByName: jest.fn((name: string) => measures.filter((m) => m.name === name)),
        clearMeasures: jest.fn(),
        clearMarks: jest.fn(),
      } as unknown as Performance;
      Object.defineProperty(globalThis, 'performance', { value: perf, configurable: true });

      const sink = jest.fn();
      setPerfDiagnosticsSink(sink);

      markPerf('ralph-nav-start', { section: 'metrics' });
      markSecondaryReady('metrics');

      expect(markSpy).toHaveBeenCalledWith(
        'ralph-secondary-ready',
        expect.objectContaining({ detail: expect.objectContaining({ section: 'metrics' }) }),
      );
      expect(sink).toHaveBeenCalledWith({
        name: 'ralph-secondary-ready',
        durationMs: 5,
        section: 'metrics',
      });
    });
  });
});
