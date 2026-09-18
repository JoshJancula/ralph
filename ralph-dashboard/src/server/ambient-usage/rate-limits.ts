import type { AmbientRateLimitWindow } from './types';

function toIsoFromEpochSeconds(value: unknown): string | null {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return new Date(value * 1000).toISOString();
  }
  if (typeof value === 'string' && value.trim()) {
    const asNum = Number(value);
    if (Number.isFinite(asNum) && asNum > 1e9) {
      return new Date(asNum * 1000).toISOString();
    }
    const parsed = Date.parse(value);
    if (!Number.isNaN(parsed)) {
      return new Date(parsed).toISOString();
    }
  }
  return null;
}

function resetsInSeconds(resetsAt: string | null): number | null {
  if (!resetsAt) {
    return null;
  }
  const ms = Date.parse(resetsAt);
  if (Number.isNaN(ms)) {
    return null;
  }
  return Math.max(0, Math.round((ms - Date.now()) / 1000));
}

export function buildRateWindow(
  id: string,
  label: string,
  usedPercent: unknown,
  resetsAtRaw: unknown,
): AmbientRateLimitWindow | null {
  const used =
    typeof usedPercent === 'number' && Number.isFinite(usedPercent)
      ? Math.min(100, Math.max(0, usedPercent))
      : null;
  if (used === null) {
    return null;
  }
  const resets_at = toIsoFromEpochSeconds(resetsAtRaw);
  return {
    id,
    label,
    used_percent: Math.round(used * 10) / 10,
    resets_at,
    resets_in_seconds: resetsInSeconds(resets_at),
  };
}

export function sortRateLimits(windows: AmbientRateLimitWindow[]): AmbientRateLimitWindow[] {
  const order = ['session', 'five_hour', '5h', 'primary', 'weekly', 'seven_day', 'secondary', 'wk'];
  return [...windows].sort((a, b) => {
    const ai = order.indexOf(a.id);
    const bi = order.indexOf(b.id);
    if (ai !== -1 || bi !== -1) {
      return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
    }
    return a.label.localeCompare(b.label);
  });
}
