import type { AmbientUsageDateScope, AmbientUsageQuery } from './types';

function parseDateOnly(raw: string | undefined): Date | null {
  if (!raw?.trim()) {
    return null;
  }
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw.trim());
  if (!match) {
    return null;
  }
  const year = Number(match[1]);
  const month = Number(match[2]) - 1;
  const day = Number(match[3]);
  const d = new Date(Date.UTC(year, month, day));
  if (Number.isNaN(d.getTime())) {
    return null;
  }
  return d;
}

export function buildAmbientDateScope(query: AmbientUsageQuery): AmbientUsageDateScope {
  const fromDate = parseDateOnly(query.dateFrom);
  const toDate = parseDateOnly(query.dateTo);
  const from = fromDate ? query.dateFrom!.trim() : null;
  const to = toDate ? query.dateTo!.trim() : null;

  if (from && to) {
    return { from, to, label: `${from} to ${to}` };
  }
  if (from) {
    return { from, to: null, label: `From ${from}` };
  }
  if (to) {
    return { from: null, to, label: `Through ${to}` };
  }
  return { from: null, to: null, label: 'All available history' };
}

export function timestampInDateScope(
  isoTimestamp: string | undefined,
  scope: AmbientUsageDateScope,
): boolean {
  if (!isoTimestamp?.trim()) {
    return scope.from === null && scope.to === null;
  }
  const ts = Date.parse(isoTimestamp);
  if (Number.isNaN(ts)) {
    return false;
  }
  const day = isoTimestamp.slice(0, 10);
  if (scope.from && day < scope.from) {
    return false;
  }
  if (scope.to && day > scope.to) {
    return false;
  }
  return true;
}
