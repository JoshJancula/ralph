/**
 * Formats a duration in seconds for display (e.g. "1h 36m 40s", "2m 5s", "45.6s", "0s").
 * Non-finite or negative values become "0s".
 */
export function formatElapsedSeconds(value: number): string {
  if (!Number.isFinite(value) || value < 0) {
    return '0s';
  }
  if (value === 0) {
    return '0s';
  }

  let rem = value;
  const h = Math.floor(rem / 3600);
  rem -= h * 3600;
  const m = Math.floor(rem / 60);
  const s = rem - m * 60;

  const parts: string[] = [];
  if (h > 0) {
    parts.push(`${h}h`);
  }
  if (m > 0) {
    parts.push(`${m}m`);
  }

  const secIsZero = Math.abs(s) < 1e-6;
  if (!secIsZero || parts.length === 0) {
    parts.push(`${formatSecondsPart(s)}s`);
  }

  return parts.join(' ');
}

function formatSecondsPart(s: number): string {
  if (!Number.isFinite(s)) {
    return '0';
  }
  if (Math.abs(s - Math.round(s)) < 1e-6) {
    return String(Math.round(s));
  }
  return s.toFixed(1);
}
