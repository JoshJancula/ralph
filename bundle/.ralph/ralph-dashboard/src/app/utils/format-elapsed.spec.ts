import { describe, expect, it } from 'vitest';
import { formatElapsedSeconds } from './format-elapsed';

describe('formatElapsedSeconds', () => {
  it('returns 0s for non-finite or negative values', () => {
    expect(formatElapsedSeconds(NaN)).toBe('0s');
    expect(formatElapsedSeconds(Number.POSITIVE_INFINITY)).toBe('0s');
    expect(formatElapsedSeconds(-1)).toBe('0s');
  });

  it('formats zero', () => {
    expect(formatElapsedSeconds(0)).toBe('0s');
  });

  it('formats seconds and sub-second values', () => {
    expect(formatElapsedSeconds(5)).toBe('5s');
    expect(formatElapsedSeconds(45.6)).toBe('45.6s');
    expect(formatElapsedSeconds(8.5)).toBe('8.5s');
    expect(formatElapsedSeconds(0.4)).toBe('0.4s');
  });

  it('formats minutes and seconds', () => {
    expect(formatElapsedSeconds(90)).toBe('1m 30s');
    expect(formatElapsedSeconds(60)).toBe('1m');
    expect(formatElapsedSeconds(125.4)).toBe('2m 5.4s');
  });

  it('formats hours, minutes, and seconds', () => {
    expect(formatElapsedSeconds(5800)).toBe('1h 36m 40s');
    expect(formatElapsedSeconds(3600)).toBe('1h');
    expect(formatElapsedSeconds(3661)).toBe('1h 1m 1s');
    expect(formatElapsedSeconds(3605)).toBe('1h 5s');
  });
});
