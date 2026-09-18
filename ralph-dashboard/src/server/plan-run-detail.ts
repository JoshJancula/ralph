export const FILE_ROLE_LABELS: Record<string, string> = {
  'plan-usage-summary.json': 'Plan usage summary',
  'invocation-usage.json': 'Invocation usage history',
  'run-manifest.json': 'Run manifest',
  'overlay-timeline.jsonl': 'Overlay compaction timeline',
};

export type OperatorNext = { label: string; description: string; enabled: boolean; disabledReason?: string };

export function classifyFiles(files: string[]) {
  const summary: Array<{ path: string; label: string }> = [];
  const raw: string[] = [];
  for (const path of files) {
    const name = path.split('/').pop() ?? path;
    if (FILE_ROLE_LABELS[name]) summary.push({ path, label: FILE_ROLE_LABELS[name]! });
    else raw.push(path);
  }
  return { summary, raw };
}

export function buildRunTimeline(runId: string, records: Array<Record<string, unknown>>) {
  return records
    .filter((record) => record['run_id'] === runId)
    .map((record) => ({
      at: String(record['ended_at'] ?? record['completed_at'] ?? record['timestamp'] ?? ''),
      prose: String(record['event'] ?? record['status'] ?? 'run activity'),
    }))
    .sort((a, b) => a.at.localeCompare(b.at));
}

export function buildOperatorNext(status: string): OperatorNext {
  return status === 'running'
    ? { label: 'Monitor run', description: 'This run is still active.', enabled: true }
    : { label: 'Inspect artifacts', description: 'Review the retained run evidence.', enabled: true };
}

export function buildResumeAffordance(input: { runId: string; planPath?: string; resumableTodoCount: number }) {
  const planArg = input.planPath && input.planPath.trim() ? input.planPath : '<plan>'
  return {
    resumableTodoCount: input.resumableTodoCount,
    command: `ralph run --plan ${planArg} --resume-run ${input.runId}`,
  };
}

import type { PlanRunFilesModel } from './plan-run-evidence';

export function enrichPlanRunDetail(input: {
  runId: string;
  status?: string;
  filesModel: PlanRunFilesModel;
  records?: Array<Record<string, unknown>>;
  planKey?: string;
  planPath?: string;
  resumableTodoCount?: number;
}) {
  return {
    runId: input.runId,
    files: input.filesModel,
    timeline: buildRunTimeline(input.runId, input.records ?? []),
    operatorNext: buildOperatorNext(input.status ?? 'unknown'),
    discoverReport: input.planKey ? `/api/metrics/discover/${encodeURIComponent(input.planKey)}` : null,
    resume: buildResumeAffordance({
      runId: input.runId,
      planPath: input.planPath,
      resumableTodoCount: input.resumableTodoCount ?? 0,
    }),
  };
}
