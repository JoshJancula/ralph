import {
  GRAPH_FILE_ROLE_LABELS,
  classifyGraphFiles,
  enrichGraphRunDetail,
  parseRoutingDecisions,
} from '../src/server/graph-run-detail';

describe('graph-run-detail routing decisions', () => {
  it('labels events.jsonl as a graph event journal', () => {
    expect(GRAPH_FILE_ROLE_LABELS['events.jsonl']).toBe('Graph event journal');
    const classified = classifyGraphFiles(['run.json', 'events.jsonl', 'nodes/a.json']);
    expect(classified.summary).toEqual(
      expect.arrayContaining([
        { path: 'events.jsonl', label: 'Graph event journal' },
      ]),
    );
    expect(classified.raw).toEqual(['nodes/a.json']);
  });

  it('parses routing-decision events from a seeded fixture journal', () => {
    const events: Array<Record<string, unknown>> = [
      {
        schemaVersion: 1,
        sequence: 3,
        timestamp: '2026-01-02T00:00:03Z',
        runId: 'run-1',
        event: 'node-ready',
        nodeId: 'classify',
        details: {},
      },
      {
        schemaVersion: 1,
        sequence: 4,
        timestamp: '2026-01-02T00:00:04Z',
        runId: 'run-1',
        event: 'routing-decision',
        nodeId: 'classify',
        attemptId: null,
        details: {
          selectedTarget: 'scope-request',
          alternatives: ['deep-investigation', 'close'],
          reason: 'jev: high-confidence',
          confidence: 0.91,
          source: 'jev',
          questionSetId: 'graph.router-confidence',
          registryVersion: '2',
        },
      },
      {
        schemaVersion: 1,
        sequence: 7,
        timestamp: '2026-01-02T00:00:07Z',
        runId: 'run-1',
        event: 'routing-decision',
        nodeId: 'qa-gate',
        details: {
          selectedTarget: 'publish',
          alternatives: ['rework'],
          reason: 'conditional-outcome:passed',
          confidence: null,
          source: 'agent',
          questionSetId: '',
          registryVersion: '1',
        },
      },
    ];

    const decisions = parseRoutingDecisions(events);
    expect(decisions).toHaveLength(2);
    expect(decisions[0]).toMatchObject({
      nodeId: 'classify',
      selectedTarget: 'scope-request',
      alternatives: ['deep-investigation', 'close'],
      reason: 'jev: high-confidence',
      confidence: 0.91,
      source: 'jev',
      registryVersion: '2',
      questionSetId: 'graph.router-confidence',
      sequence: 4,
    });
    expect(decisions[1]).toMatchObject({
      nodeId: 'qa-gate',
      selectedTarget: 'publish',
      source: 'agent',
      confidence: null,
      registryVersion: '1',
    });
  });

  it('returns an empty routing list when events are absent or unrelated', () => {
    expect(parseRoutingDecisions([])).toEqual([]);
    expect(
      parseRoutingDecisions([
        { event: 'node-terminal', nodeId: 'implement', details: { outcome: 'succeeded' } },
        { event: 'routing-decision', nodeId: 'broken', details: 'not-an-object' },
      ]),
    ).toEqual([
      expect.objectContaining({
        nodeId: 'broken',
        selectedTarget: '',
        alternatives: [],
        source: 'unknown',
        registryVersion: '1',
      }),
    ]);

    const enriched = enrichGraphRunDetail({
      runId: 'run-empty',
      namespace: 'demo',
      status: 'succeeded',
      files: ['run.json', 'graph.json'],
    });
    expect(enriched.routingDecisions).toEqual([]);
    expect(enriched.files.summary.some((entry) => entry.path === 'events.jsonl')).toBe(false);
  });

  it('includes events.jsonl in enrichment file roles when present', () => {
    const enriched = enrichGraphRunDetail({
      runId: 'run-seeded',
      namespace: 'demo',
      status: 'succeeded',
      files: ['run.json', 'graph.json', 'events.jsonl', 'observability.jsonl'],
      events: [
        {
          event: 'routing-decision',
          sequence: 1,
          timestamp: '2026-01-02T00:00:01Z',
          nodeId: 'router',
          details: {
            selectedTarget: 'path-a',
            alternatives: ['path-b'],
            reason: 'default-fallback',
            confidence: 0.2,
            source: 'default',
            questionSetId: 'graph.router-confidence',
            registryVersion: '1',
          },
        },
      ],
    });
    expect(enriched.files.summary).toEqual(
      expect.arrayContaining([{ path: 'events.jsonl', label: 'Graph event journal' }]),
    );
    expect(enriched.routingDecisions).toHaveLength(1);
    expect(enriched.routingDecisions[0]?.source).toBe('default');
  });
});
