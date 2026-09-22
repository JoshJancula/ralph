/**
 * Display-graph projection of a workflow's inspected topology.
 *
 * Built from `ralph workflow inspect --format json` (the same read-only
 * parser/preview path the runtime uses) plus bounded rework unrolling that
 * mirrors `expand_rework_nodes` in plan-todo.sh. Angular never reverse-
 * engineers edges from YAML.
 */

export type DisplayGraphEdgeKind =
  | 'dependency'
  | 'sequential'
  | 'plan-handoff'
  | 'rework-passed'
  | 'rework-changes-required'
  | 'rework'
  | 'request-changes';

export type DisplayGraphNodeKind =
  | 'agent'
  | 'planner'
  | 'plan-consumer'
  | 'gate'
  | 'approval'
  | 'integrate'
  | 'join'
  | 'checkpoint'
  | 'router'
  | 'input'
  | 'consensus'
  | 'stage';

export type DisplayGraphDerivedFrom = 'stage' | 'rework' | 'join';

export interface WorkflowDisplayGraphNode {
  readonly id: string;
  readonly label: string;
  readonly kind: DisplayGraphNodeKind;
  readonly stageType: string;
  readonly authored: boolean;
  readonly derivedFrom: DisplayGraphDerivedFrom;
  readonly planRole: 'generate' | 'accept' | 'execute' | null;
  readonly waveIndex: number;
  readonly loopBackTo: string | null;
  readonly changesTarget: string | null;
}

export interface WorkflowDisplayGraphEdge {
  readonly from: string;
  readonly to: string;
  readonly kind: DisplayGraphEdgeKind;
  readonly label: string | null;
  /** True for frozen schedule edges; false for feedback/loopback evidence. */
  readonly scheduleEdge: boolean;
}

export interface WorkflowDisplayGraph {
  readonly workflowId: string;
  readonly mode: 'sequential' | 'dependency';
  readonly sourceKind: string;
  readonly sourcePath: string;
  readonly maxReworkIterations: number | null;
  readonly nodes: readonly WorkflowDisplayGraphNode[];
  readonly edges: readonly WorkflowDisplayGraphEdge[];
  readonly waves: readonly (readonly string[])[];
}

export interface WorkflowDisplayGraphError {
  readonly code: string;
  readonly message: string;
  readonly diagnostics: string;
  readonly sourcePath: string | null;
  readonly sourceKind: string | null;
  readonly line: number | null;
  readonly column: number | null;
}

interface InspectStage {
  readonly id?: unknown;
  readonly type?: unknown;
  readonly dependsOn?: unknown;
  readonly planner?: unknown;
  readonly planFrom?: unknown;
  readonly planFile?: unknown;
  readonly loopBackTo?: unknown;
  readonly maxIterations?: unknown;
  readonly onExhausted?: unknown;
  readonly changesTarget?: unknown;
  readonly question?: unknown;
}

interface InspectModel {
  readonly name?: unknown;
  readonly mode?: unknown;
  readonly source?: { readonly path?: unknown; readonly scope?: unknown };
  readonly stages?: unknown;
  readonly derivedNodes?: unknown;
  readonly schedule?: { readonly waves?: unknown; readonly kind?: unknown };
  readonly planFromEdges?: unknown;
  readonly planStages?: {
    readonly generate?: unknown;
    readonly accept?: unknown;
    readonly execute?: unknown;
  };
  readonly planInput?: { readonly declared?: unknown; readonly stage?: unknown };
  readonly approvals?: unknown;
  readonly authoredOrder?: unknown;
}

export interface BuildDisplayGraphOptions {
  readonly maxReworkIterations?: number | null;
  readonly workflowId?: string;
}

function asText(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((item) => asText(item)).filter(Boolean);
}

function parseLineFromDiagnostics(diagnostics: string): number | null {
  const match = diagnostics.match(/\bline\s+(\d+)\b/i) ?? diagnostics.match(/:(\d+)(?::\d+)?\b/);
  if (!match) {
    return null;
  }
  const line = Number(match[1]);
  return Number.isFinite(line) ? line : null;
}

function nodeKindFor(stage: InspectStage, planRoles: { generate: Set<string>; accept: Set<string>; execute: Set<string> }): DisplayGraphNodeKind {
  const id = asText(stage.id);
  const type = asText(stage.type) || 'agent';
  if (type === 'gate') return 'gate';
  if (type === 'approval') return 'approval';
  if (type === 'integrate') return 'integrate';
  if (type === 'join') return 'join';
  if (type === 'checkpoint') return 'checkpoint';
  if (type === 'router') return 'router';
  if (type === 'input') return 'input';
  if (type === 'consensus') return 'consensus';
  if (stage.planner || planRoles.generate.has(id)) return 'planner';
  if (asText(stage.planFrom) || planRoles.accept.has(id) || planRoles.execute.has(id)) return 'plan-consumer';
  if (type === 'agent') return 'agent';
  return 'stage';
}

function planRoleFor(
  id: string,
  planRoles: { generate: Set<string>; accept: Set<string>; execute: Set<string> },
): 'generate' | 'accept' | 'execute' | null {
  if (planRoles.generate.has(id)) return 'generate';
  if (planRoles.accept.has(id)) return 'accept';
  if (planRoles.execute.has(id)) return 'execute';
  return null;
}

function edgeKey(from: string, to: string, kind: DisplayGraphEdgeKind): string {
  return `${from}\0${to}\0${kind}`;
}

/**
 * Unroll a loopBackTo review stage the same way expand_rework_nodes does:
 * `<target>-r<n>`, `<review>-r<n>`, and `<review>-approved` with passed /
 * changes-required conditions. Preserves frozen acyclic topology.
 */
function expandRework(
  review: InspectStage,
  iterations: number,
): { nodes: WorkflowDisplayGraphNode[]; edges: WorkflowDisplayGraphEdge[] } {
  const reviewId = asText(review.id);
  const targetId = asText(review.loopBackTo);
  const onExhausted = asText(review.onExhausted) || 'fail';
  if (!reviewId || !targetId || iterations < 1) {
    return { nodes: [], edges: [] };
  }

  const nodes: WorkflowDisplayGraphNode[] = [];
  const edges: WorkflowDisplayGraphEdge[] = [];
  const approvedId = `${reviewId}-approved`;

  nodes.push({
    id: approvedId,
    label: approvedId,
    kind: 'join',
    stageType: 'join',
    authored: false,
    derivedFrom: 'rework',
    planRole: null,
    waveIndex: -1,
    loopBackTo: null,
    changesTarget: null,
  });

  edges.push({
    from: reviewId,
    to: approvedId,
    kind: 'rework-passed',
    label: 'passed',
    scheduleEdge: true,
  });

  let prevReviewId = reviewId;
  for (let n = 1; n <= iterations; n += 1) {
    const targetRoundId = `${targetId}-r${n}`;
    const reviewRoundId = `${reviewId}-r${n}`;

    nodes.push({
      id: targetRoundId,
      label: targetRoundId,
      kind: 'plan-consumer',
      stageType: 'agent',
      authored: false,
      derivedFrom: 'rework',
      planRole: 'execute',
      waveIndex: -1,
      loopBackTo: null,
      changesTarget: null,
    });
    nodes.push({
      id: reviewRoundId,
      label: reviewRoundId,
      kind: 'agent',
      stageType: 'agent',
      authored: false,
      derivedFrom: 'rework',
      planRole: null,
      waveIndex: -1,
      loopBackTo: targetId,
      changesTarget: null,
    });

    edges.push({
      from: prevReviewId,
      to: targetRoundId,
      kind: 'rework-changes-required',
      label: 'changes-required',
      scheduleEdge: true,
    });
    edges.push({
      from: targetRoundId,
      to: reviewRoundId,
      kind: 'rework',
      label: null,
      scheduleEdge: true,
    });
    edges.push({
      from: reviewRoundId,
      to: approvedId,
      kind: 'rework-passed',
      label: 'passed',
      scheduleEdge: true,
    });

    if (n < iterations) {
      prevReviewId = reviewRoundId;
    } else if (onExhausted === 'proceed') {
      edges.push({
        from: reviewRoundId,
        to: approvedId,
        kind: 'rework-changes-required',
        label: 'changes-required',
        scheduleEdge: true,
      });
    }
  }

  return { nodes, edges };
}

function resolveIterations(stage: InspectStage, pipelineMax: number | null): number | null {
  const stageMax = stage.maxIterations;
  if (typeof stageMax === 'number' && Number.isInteger(stageMax) && stageMax >= 1) {
    return stageMax;
  }
  if (typeof stageMax === 'string' && /^\d+$/.test(stageMax.trim())) {
    const parsed = Number(stageMax.trim());
    if (parsed >= 1) return parsed;
  }
  if (typeof pipelineMax === 'number' && pipelineMax >= 1) {
    return pipelineMax;
  }
  return null;
}

export function buildDisplayGraphError(options: {
  readonly code: string;
  readonly message: string;
  readonly diagnostics: string;
  readonly sourcePath?: string | null;
  readonly sourceKind?: string | null;
}): WorkflowDisplayGraphError {
  const diagnostics = options.diagnostics.trim();
  return {
    code: options.code,
    message: options.message,
    diagnostics,
    sourcePath: options.sourcePath ?? null,
    sourceKind: options.sourceKind ?? null,
    line: parseLineFromDiagnostics(diagnostics),
    column: null,
  };
}

/**
 * Project inspect JSON into a selectable display graph. Returns an error
 * object (never an empty success graph) when the inspect model cannot yield
 * topology.
 */
export function buildDisplayGraphFromInspect(
  inspect: unknown,
  options: BuildDisplayGraphOptions = {},
): { ok: true; graph: WorkflowDisplayGraph } | { ok: false; error: WorkflowDisplayGraphError } {
  if (!inspect || typeof inspect !== 'object') {
    return {
      ok: false,
      error: buildDisplayGraphError({
        code: 'inspect-invalid',
        message: 'Workflow inspect payload is missing or not an object.',
        diagnostics: 'Expected ralph workflow inspect --format json object.',
      }),
    };
  }

  const model = inspect as InspectModel;
  const sourcePath = asText(model.source?.path) || null;
  const sourceKind = asText(model.source?.scope) || 'unknown';
  const stagesRaw = model.stages;
  if (!Array.isArray(stagesRaw) || stagesRaw.length === 0) {
    return {
      ok: false,
      error: buildDisplayGraphError({
        code: 'no-stages',
        message: 'Workflow has no stages to graph.',
        diagnostics: 'inspect.stages is missing or empty; the definition cannot produce a topology.',
        sourcePath,
        sourceKind,
      }),
    };
  }

  const stages = stagesRaw as InspectStage[];
  const mode = asText(model.mode) === 'sequential' ? 'sequential' : 'dependency';
  const workflowId = options.workflowId || asText(model.name) || 'workflow';
  const pipelineMax = options.maxReworkIterations ?? null;

  const generate = new Set(asStringList(model.planStages?.generate));
  const accept = new Set(asStringList(model.planStages?.accept));
  const execute = new Set(asStringList(model.planStages?.execute));
  const planRoles = { generate, accept, execute };

  const nodeMap = new Map<string, WorkflowDisplayGraphNode>();
  const edgeMap = new Map<string, WorkflowDisplayGraphEdge>();

  const addNode = (node: WorkflowDisplayGraphNode): void => {
    if (!nodeMap.has(node.id)) {
      nodeMap.set(node.id, node);
    }
  };

  const addEdge = (edge: WorkflowDisplayGraphEdge): void => {
    const key = edgeKey(edge.from, edge.to, edge.kind);
    if (!edgeMap.has(key)) {
      edgeMap.set(key, edge);
    }
  };

  const waveLists: string[][] = Array.isArray(model.schedule?.waves)
    ? (model.schedule!.waves as unknown[])
        .map((wave) => asStringList(wave))
        .filter((wave) => wave.length > 0)
    : [];
  const waveIndexById = new Map<string, number>();
  waveLists.forEach((wave, index) => {
    for (const id of wave) {
      waveIndexById.set(id, index);
    }
  });

  for (const stage of stages) {
    const id = asText(stage.id);
    if (!id) continue;
    const stageType = asText(stage.type) || 'agent';
    addNode({
      id,
      label: id,
      kind: nodeKindFor(stage, planRoles),
      stageType,
      authored: true,
      derivedFrom: 'stage',
      planRole: planRoleFor(id, planRoles),
      waveIndex: waveIndexById.get(id) ?? -1,
      loopBackTo: asText(stage.loopBackTo) || null,
      changesTarget: asText(stage.changesTarget) || null,
    });
  }

  const derived = Array.isArray(model.derivedNodes) ? model.derivedNodes : [];
  for (const entry of derived) {
    if (!entry || typeof entry !== 'object') continue;
    const d = entry as { id?: unknown; type?: unknown; from?: unknown };
    const id = asText(d.id);
    if (!id) continue;
    addNode({
      id,
      label: id,
      kind: 'join',
      stageType: asText(d.type) || 'join',
      authored: false,
      derivedFrom: 'join',
      planRole: null,
      waveIndex: waveIndexById.get(id) ?? -1,
      loopBackTo: null,
      changesTarget: null,
    });
  }

  if (mode === 'sequential') {
    for (let i = 0; i < waveLists.length - 1; i += 1) {
      for (const from of waveLists[i] ?? []) {
        for (const to of waveLists[i + 1] ?? []) {
          addEdge({
            from,
            to,
            kind: 'sequential',
            label: null,
            scheduleEdge: true,
          });
        }
      }
    }
  } else {
    for (const stage of stages) {
      const id = asText(stage.id);
      if (!id) continue;
      for (const dep of asStringList(stage.dependsOn)) {
        if (!nodeMap.has(dep) && !asText(stage.loopBackTo)) {
          // Keep edges to derived joins even if they arrive later via rework.
        }
        addEdge({
          from: dep,
          to: id,
          kind: 'dependency',
          label: null,
          scheduleEdge: true,
        });
        if (!nodeMap.has(dep)) {
          addNode({
            id: dep,
            label: dep,
            // Inspect does not carry frozen-node provenance. Never guess a
            // join from an id suffix: real run graphs supply the compiler's
            // logicalStage/attempt fields instead.
            kind: 'stage',
            stageType: 'stage',
            authored: false,
            derivedFrom: 'stage',
            planRole: null,
            waveIndex: waveIndexById.get(dep) ?? -1,
            loopBackTo: null,
            changesTarget: null,
          });
        }
      }
    }

    const planFromEdges = Array.isArray(model.planFromEdges) ? model.planFromEdges : [];
    for (const entry of planFromEdges) {
      if (!entry || typeof entry !== 'object') continue;
      const e = entry as { from?: unknown; to?: unknown };
      const from = asText(e.from);
      const to = asText(e.to);
      if (!from || !to) continue;
      addEdge({
        from,
        to,
        kind: 'plan-handoff',
        label: 'plan handoff',
        scheduleEdge: false,
      });
    }

    const approvals = Array.isArray(model.approvals) ? model.approvals : [];
    for (const entry of approvals) {
      if (!entry || typeof entry !== 'object') continue;
      const g = entry as { id?: unknown; changesTarget?: unknown };
      const from = asText(g.id);
      const to = asText(g.changesTarget);
      if (!from || !to) continue;
      addEdge({
        from,
        to,
        kind: 'request-changes',
        label: 'request-changes',
        scheduleEdge: false,
      });
    }
  }

  let maxReworkUsed: number | null = pipelineMax;
  for (const stage of stages) {
    if (!asText(stage.loopBackTo)) continue;
    const iterations = resolveIterations(stage, pipelineMax);
    if (iterations == null) {
      // Label-only: keep authored loopBackTo on the node; do not invent rounds.
      continue;
    }
    maxReworkUsed = iterations;
    const expanded = expandRework(stage, iterations);
    for (const node of expanded.nodes) {
      addNode(node);
    }
    for (const edge of expanded.edges) {
      addEdge(edge);
    }
  }

  // Assign wave indices for derived/rework nodes that were not in inspect waves.
  const nodes = [...nodeMap.values()].map((node) => {
    if (node.waveIndex >= 0) return node;
    return { ...node, waveIndex: waveIndexById.get(node.id) ?? node.waveIndex };
  });

  if (nodes.length === 0) {
    return {
      ok: false,
      error: buildDisplayGraphError({
        code: 'empty-graph',
        message: 'Display graph produced no nodes.',
        diagnostics: 'Inspect stages were present but none had usable ids.',
        sourcePath,
        sourceKind,
      }),
    };
  }

  const waves =
    waveLists.length > 0
      ? waveLists
      : [nodes.filter((n) => n.authored).map((n) => n.id)];

  return {
    ok: true,
    graph: {
      workflowId,
      mode,
      sourceKind,
      sourcePath: sourcePath ?? '',
      maxReworkIterations: maxReworkUsed,
      nodes,
      edges: [...edgeMap.values()],
      waves,
    },
  };
}
