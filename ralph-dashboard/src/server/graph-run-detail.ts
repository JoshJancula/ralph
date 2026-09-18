export const GRAPH_FILE_ROLE_LABELS: Record<string, string> = {
  'run.json': 'Graph run record',
  'graph.json': 'Compiled graph',
  'observability.jsonl': 'Observability events',
};

export type GraphOperatorNext = { label: string; description: string; enabled: boolean; disabledReason?: string };

export function classifyGraphFiles(files: string[]) {
  const summary: Array<{ path: string; label: string }> = [];
  const raw: string[] = [];
  for (const path of files) {
    const name = path.split('/').pop() ?? path;
    if (GRAPH_FILE_ROLE_LABELS[name]) {
      summary.push({ path, label: GRAPH_FILE_ROLE_LABELS[name]! });
    } else {
      raw.push(path);
    }
  }
  return { summary, raw };
}

export function buildGraphRunTimeline(records: Array<Record<string, unknown>>) {
  return records.map((record) => ({
    at: String(record['at'] ?? record['ended_at'] ?? record['timestamp'] ?? record['ts'] ?? ''),
    prose: String(record['event'] ?? record['type'] ?? record['status'] ?? 'graph activity'),
  })).sort((a, b) => a.at.localeCompare(b.at));
}

export function buildGraphOperatorNext(status: string): GraphOperatorNext {
  return status === 'running'
    ? { label: 'Monitor graph run', description: 'This graph run is still active.', enabled: true }
    : { label: 'Inspect graph artifacts', description: 'Review the retained graph-run evidence.', enabled: true };
}

export function enrichGraphRunDetail(input: {
  runId: string;
  namespace?: string;
  status?: string;
  files?: string[];
  records?: Array<Record<string, unknown>>;
}) {
  return {
    runId: input.runId,
    namespace: input.namespace ?? null,
    files: classifyGraphFiles(input.files ?? []),
    timeline: buildGraphRunTimeline(input.records ?? []),
    operatorNext: buildGraphOperatorNext(input.status ?? 'unknown'),
  };
}
