export const GRAPH_FILE_ROLE_LABELS: Record<string, string> = {
  'run.json': 'Graph run record',
  'graph.json': 'Compiled graph',
  'observability.jsonl': 'Observability events',
  'events.jsonl': 'Graph event journal',
};

export type GraphOperatorNext = { label: string; description: string; enabled: boolean; disabledReason?: string };

/** One routing or conditional edge selection from events.jsonl. */
export type GraphRoutingDecision = {
  nodeId: string;
  selectedTarget: string;
  alternatives: string[];
  reason: string;
  confidence: number | null;
  source: string;
  registryVersion: string;
  questionSetId: string;
  timestamp: string;
  sequence: number | null;
};

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

function stringField(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

function numberOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

/**
 * Extract routing-decision journal rows from events.jsonl records.
 * Malformed rows and non-routing events are skipped so a missing or empty
 * journal never fails the run-detail response.
 */
export function parseRoutingDecisions(records: Array<Record<string, unknown>>): GraphRoutingDecision[] {
  const decisions: GraphRoutingDecision[] = [];
  for (const record of records) {
    if (record['event'] !== 'routing-decision') {
      continue;
    }
    const detailsRaw = record['details'];
    const details =
      detailsRaw && typeof detailsRaw === 'object' && !Array.isArray(detailsRaw)
        ? (detailsRaw as Record<string, unknown>)
        : {};
    const alternativesRaw = details['alternatives'];
    const alternatives = Array.isArray(alternativesRaw)
      ? alternativesRaw.filter((item): item is string => typeof item === 'string')
      : [];
    const sequence = numberOrNull(record['sequence']);
    decisions.push({
      nodeId: stringField(record['nodeId'], '(unknown)'),
      selectedTarget: stringField(details['selectedTarget']),
      alternatives,
      reason: stringField(details['reason']),
      confidence: numberOrNull(details['confidence']),
      source: stringField(details['source'], 'unknown'),
      registryVersion: stringField(details['registryVersion'], '1'),
      questionSetId: stringField(details['questionSetId']),
      timestamp: stringField(record['timestamp']),
      sequence,
    });
  }
  return decisions.sort((a, b) => {
    if (a.sequence !== null && b.sequence !== null && a.sequence !== b.sequence) {
      return a.sequence - b.sequence;
    }
    return a.timestamp.localeCompare(b.timestamp);
  });
}

export function enrichGraphRunDetail(input: {
  runId: string;
  namespace?: string;
  status?: string;
  files?: string[];
  records?: Array<Record<string, unknown>>;
  events?: Array<Record<string, unknown>>;
}) {
  return {
    runId: input.runId,
    namespace: input.namespace ?? null,
    files: classifyGraphFiles(input.files ?? []),
    timeline: buildGraphRunTimeline(input.records ?? []),
    operatorNext: buildGraphOperatorNext(input.status ?? 'unknown'),
    routingDecisions: parseRoutingDecisions(input.events ?? []),
  };
}
