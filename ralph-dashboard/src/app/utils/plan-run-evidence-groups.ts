import type { PlanRunEvidenceEntry } from '../services/api.service';

export interface PlanRunEvidenceGroup {
  id: 'metadata' | 'execution' | 'session' | 'other';
  title: string;
  entries: readonly PlanRunEvidenceEntry[];
}

const GROUP_DEFS: Array<{ id: PlanRunEvidenceGroup['id']; title: string; categories: Set<string> }> = [
  {
    id: 'metadata',
    title: 'Run metadata and summaries',
    categories: new Set(['run-metadata', 'usage-summary', 'runtime-config']),
  },
  {
    id: 'execution',
    title: 'Execution output and activity',
    categories: new Set(['execution-output', 'tool-telemetry', 'overlay']),
  },
  {
    id: 'session',
    title: 'Prompts and session context',
    categories: new Set(['session-context']),
  },
  {
    id: 'other',
    title: 'Other files',
    categories: new Set(['other']),
  },
];

export function groupPlanRunEvidence(entries: readonly PlanRunEvidenceEntry[]): PlanRunEvidenceGroup[] {
  const assigned = new Set<string>();
  const groups: PlanRunEvidenceGroup[] = [];

  for (const def of GROUP_DEFS) {
    const matched = entries.filter((entry) => {
      if (assigned.has(entry.id)) {
        return false;
      }
      if (def.id === 'other') {
        return !GROUP_DEFS.some(
          (other) => other.id !== 'other' && other.categories.has(entry.category),
        );
      }
      return def.categories.has(entry.category);
    });
    for (const entry of matched) {
      assigned.add(entry.id);
    }
    if (matched.length > 0) {
      groups.push({ id: def.id, title: def.title, entries: matched });
    }
  }

  return groups;
}

export function concisePlanRunEvidencePath(path: string, planKey: string): string {
  const normalized = path.replace(/\\/g, '/');
  const prefixes = [
    `logs/${planKey}/`,
    `runtime-config/${planKey}/`,
    `internal/runtime-config/${planKey}/`,
    `internal/sessions/${planKey}/`,
    `sessions/${planKey}/`,
  ];
  for (const prefix of prefixes) {
    if (normalized.startsWith(prefix)) {
      return normalized.slice(prefix.length);
    }
  }
  if (normalized.startsWith('logs/')) {
    return normalized.slice('logs/'.length);
  }
  if (normalized.startsWith('runtime-config/')) {
    return normalized.slice('runtime-config/'.length);
  }
  if (normalized.startsWith('internal/runtime-config/')) {
    return normalized.slice('internal/runtime-config/'.length);
  }
  return normalized;
}

export function formatEvidenceByteSize(sizeBytes: number | null): string {
  if (sizeBytes == null || sizeBytes < 0) {
    return 'size unknown';
  }
  if (sizeBytes < 1024) {
    return `${sizeBytes} B`;
  }
  if (sizeBytes < 1024 * 1024) {
    return `${(sizeBytes / 1024).toFixed(1)} KB`;
  }
  return `${(sizeBytes / (1024 * 1024)).toFixed(1)} MB`;
}
