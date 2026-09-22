/**
 * Dashboard enrichment for `ralph workflow status --json` plus actions list.
 * Builds a stage map, chronological timeline, and operator-next panel from
 * supervisor records — never from agent prose or log tails.
 */

export type OperatorActionKind = 'respond' | 'resume' | 'reset' | 'cancel' | 'none' | 'other';

export type ActionStatus = 'outstanding' | 'answered' | 'consumed' | 'cancelled';

export interface RunActionRow {
  readonly requestId: string;
  readonly kind: string;
  readonly stageId?: string | null;
  readonly question?: string | null;
  readonly status?: string | null;
  readonly choices?: readonly string[] | null;
  readonly decision?: unknown;
  readonly consumed?: unknown;
  readonly createdAt?: string | null;
  readonly decidedAt?: string | null;
  readonly message?: string | null;
}

export interface StageMapEntry {
  readonly id: string;
  readonly state: string;
  readonly attempt: number;
  readonly stageKind: string;
  readonly todoProgress: { readonly completed: number; readonly total: number; readonly currentTodoId: string | null } | null;
  readonly requiredEvidence: readonly string[];
  readonly producedEvidence: readonly string[];
  readonly actionRequestId: string | null;
  readonly requestState: string | null;
  readonly nextPermittedAction: string | null;
  readonly sourcePlanPath: string | null;
  readonly controlPlanPath: string | null;
  readonly planSourceKind: string | null;
  readonly reasonCode: string | null;
  readonly summary: string | null;
  readonly reworkRound: number;
  readonly logScope: string | null;
}

export interface TimelineEvent {
  readonly id: string;
  readonly timestamp: string;
  readonly type: string;
  readonly stageId: string | null;
  readonly message: string;
}

export interface OperatorNext {
  readonly kind: OperatorActionKind;
  readonly label: string;
  readonly description: string;
  readonly enabled: boolean;
  readonly disabledReason: string | null;
  readonly stageId: string | null;
  readonly requestId: string | null;
  readonly resetStageId: string | null;
  readonly argv: readonly string[];
}

export interface ActionDetail {
  readonly requestId: string;
  readonly kind: string;
  readonly stageId: string | null;
  readonly question: string;
  readonly status: ActionStatus;
  readonly choices: readonly string[];
  readonly decision: string | null;
  readonly decidedAt: string | null;
  readonly message: string | null;
  readonly enabled: boolean;
  readonly disabledReason: string | null;
}

export interface WorkflowRunDetailView {
  readonly stageMap: readonly StageMapEntry[];
  readonly timeline: readonly TimelineEvent[];
  readonly operatorNext: OperatorNext;
  readonly actions: readonly ActionDetail[];
}

export interface EnrichedWorkflowRunDetail {
  readonly schemaVersion: number;
  readonly run: Record<string, unknown>;
  readonly stages: readonly Record<string, unknown>[];
  readonly diagnosis: Record<string, unknown>;
  readonly nextAction: unknown;
  readonly detail: WorkflowRunDetailView;
}

const REASON_LABELS: Readonly<Record<string, string>> = {
  'operator-request': 'Interrupted by the operator',
  'operator-input': 'Waiting for operator input',
  'human-approval': 'Waiting for an approval decision',
  'human-changes-requested': 'Operator requested changes; reset the changes target, then resume',
  'unmet-dependency': 'Waiting on an unmet upstream dependency',
  'failed-prerequisite': 'A prerequisite stage failed',
  'missing-artifact': 'A required artifact is missing',
  'invalid-artifact': 'A required artifact failed validation',
  'loop-exhausted': 'Rework budget exhausted; reset the repair stage to continue',
  cycle: 'A dependency cycle blocked progress',
  'live-owner': 'Another supervisor currently owns this run',
  'stale-owner': 'The owning supervisor is gone; recover then resume',
  'stage-failed': 'A stage failed verification or execution',
  cancelled: 'Run was cancelled',
  none: 'No blocking condition',
};

const TERMINAL_STATES: ReadonlySet<string> = new Set(['succeeded', 'failed', 'cancelled']);

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .map((entry) => {
      if (typeof entry === 'string') {
        return entry;
      }
      const rec = asRecord(entry);
      if (!rec) {
        return null;
      }
      return asString(rec['path']) ?? asString(rec['name']) ?? asString(rec['id']) ?? asString(rec['summary']);
    })
    .filter((entry): entry is string => entry !== null);
}

export function translateReasonCode(reasonCode: string | null | undefined): string {
  if (!reasonCode) {
    return 'No blocking condition';
  }
  return REASON_LABELS[reasonCode] ?? reasonCode.replace(/-/g, ' ');
}

function basenameHint(path: string | null): string | null {
  if (!path) {
    return null;
  }
  const parts = path.split('/').filter(Boolean);
  return parts.length > 0 ? parts[parts.length - 1]! : path;
}

function normalizeActionStatus(raw: RunActionRow): ActionStatus {
  const explicit = asString(raw.status);
  if (explicit === 'outstanding' || explicit === 'answered' || explicit === 'consumed' || explicit === 'cancelled') {
    return explicit;
  }
  if (raw.consumed != null) {
    return 'consumed';
  }
  if (raw.decision != null) {
    return 'answered';
  }
  return 'outstanding';
}

function extractDecision(raw: RunActionRow): { decision: string | null; decidedAt: string | null; message: string | null } {
  const decisionRec = asRecord(raw.decision);
  if (decisionRec) {
    return {
      decision: asString(decisionRec['decision']),
      decidedAt: asString(decisionRec['decidedAt']) ?? asString(decisionRec['createdAt']),
      message: asString(decisionRec['message']) ?? asString(raw.message),
    };
  }
  return {
    decision: typeof raw.decision === 'string' ? raw.decision : null,
    decidedAt: asString(raw.decidedAt),
    message: asString(raw.message),
  };
}

function parseNextActionArgv(nextAction: unknown): {
  kind: OperatorActionKind;
  label: string;
  argv: string[];
  resetStageId: string | null;
} {
  const rec = asRecord(nextAction);
  if (!rec) {
    return { kind: 'none', label: 'No action required', argv: [], resetStageId: null };
  }
  const label = asString(rec['label']) ?? asString(rec['description']) ?? asString(rec['message']) ?? 'Next action';
  const argv = Array.isArray(rec['argv']) ? rec['argv'].filter((v): v is string => typeof v === 'string') : [];
  const joined = argv.join(' ');
  let resetStageId: string | null = null;
  const stageIdx = argv.indexOf('--stage');
  if (stageIdx >= 0 && stageIdx + 1 < argv.length) {
    resetStageId = argv[stageIdx + 1] ?? null;
  }
  let kind: OperatorActionKind = 'other';
  if (joined.includes('workflow reset') || argv.includes('reset')) {
    kind = 'reset';
  } else if (joined.includes('workflow resume') || argv.includes('resume')) {
    kind = 'resume';
  } else if (joined.includes('actions') || joined.includes('respond')) {
    kind = 'respond';
  } else if (joined.includes('cancel')) {
    kind = 'cancel';
  } else if (argv.length === 0 && !asString(rec['label'])) {
    kind = 'none';
  }
  return { kind, label, argv, resetStageId };
}

function stageNextPermittedAction(
  stage: Record<string, unknown>,
  diagnosis: Record<string, unknown>,
  operatorKind: OperatorActionKind,
): string | null {
  const stageId = asString(stage['id']);
  const state = asString(stage['state']) ?? 'queued';
  const requestState = asString(stage['requestState']);
  const diagnosisStage = asString(diagnosis['stageId']);
  if (stageId && diagnosisStage === stageId) {
    if (operatorKind === 'respond' && (requestState === 'outstanding' || !requestState)) {
      return 'Respond to the outstanding operator request';
    }
    if (operatorKind === 'resume') {
      return 'Resume to continue past this stage';
    }
    if (operatorKind === 'reset') {
      return 'Reset this stage (or its changes target), then resume';
    }
  }
  if (state === 'waiting' && requestState === 'outstanding') {
    return 'Respond to the outstanding operator request';
  }
  if (state === 'waiting' && (requestState === 'answered' || requestState === 'consumed')) {
    return 'Resume to consume the persisted decision';
  }
  if (state === 'failed') {
    return 'Inspect verification evidence; reset or resume if diagnosis allows';
  }
  if (state === 'running') {
    return 'Wait for the stage to finish';
  }
  if (state === 'succeeded' || state === 'skipped' || state === 'cancelled') {
    return null;
  }
  return null;
}

function buildStageMap(
  stages: readonly Record<string, unknown>[],
  diagnosis: Record<string, unknown>,
  operatorKind: OperatorActionKind,
): StageMapEntry[] {
  return stages.map((stage, index) => {
    const id = asString(stage['id']) ?? `stage-${index}`;
    const attempt = asNumber(stage['attempt'], 0);
    const completedTodos = asNumber(stage['completedTodos'], 0);
    const totalTodos = asNumber(stage['totalTodos'], 0);
    const currentTodoId = asString(stage['currentTodoId']);
    const artifacts = asStringArray(stage['artifacts']);
    const evidence = asStringArray(stage['evidence']);
    const sourcePlanPath = asString(stage['sourcePlanPath']) ?? asString(stage['originalPlanPath']);
    const controlPlanPath = asString(stage['controlPlanPath']);
    const planRunId = asString(stage['planRunId']);
    const reasonCode = asString(stage['reasonCode']) ?? (asString(diagnosis['stageId']) === id ? asString(diagnosis['reasonCode']) : null);
    const todoProgress =
      totalTodos > 0 || currentTodoId
        ? { completed: completedTodos, total: totalTodos, currentTodoId }
        : null;

    return {
      id,
      state: asString(stage['state']) ?? asString(stage['status']) ?? 'queued',
      attempt,
      stageKind: asString(stage['stageKind']) ?? 'executable',
      todoProgress,
      requiredEvidence: artifacts,
      producedEvidence: evidence.length > 0 ? evidence : artifacts,
      actionRequestId: asString(stage['requestId']),
      requestState: asString(stage['requestState']),
      nextPermittedAction: stageNextPermittedAction(stage, diagnosis, operatorKind),
      sourcePlanPath,
      controlPlanPath,
      planSourceKind: asString(stage['planSourceKind']),
      reasonCode,
      summary: reasonCode ? translateReasonCode(reasonCode) : asString(stage['terminalResult']),
      reworkRound: attempt > 1 ? attempt : 0,
      logScope: planRunId ? `plan-run:${planRunId}` : basenameHint(controlPlanPath) ? `control:${basenameHint(controlPlanPath)}` : null,
    };
  });
}

function buildTimeline(
  run: Record<string, unknown>,
  stages: readonly Record<string, unknown>[],
  diagnosis: Record<string, unknown>,
  actions: readonly RunActionRow[],
): TimelineEvent[] {
  const events: TimelineEvent[] = [];
  const runCreated = asString(run['createdAt']);
  const runId = asString(run['runId']) ?? 'run';
  if (runCreated) {
    events.push({
      id: `${runId}:created`,
      timestamp: runCreated,
      type: 'run-created',
      stageId: null,
      message: `Run created (${asString(run['workflowId']) ?? 'workflow'})`,
    });
  }

  for (const stage of stages) {
    const id = asString(stage['id']);
    if (!id) {
      continue;
    }
    const state = asString(stage['state']) ?? 'queued';
    if (state === 'skipped') {
      continue;
    }
    const createdAt = asString(stage['createdAt']) ?? runCreated ?? new Date(0).toISOString();
    const updatedAt = asString(stage['updatedAt']) ?? createdAt;
    const attempt = asNumber(stage['attempt'], 0);
    const attemptSuffix = attempt > 1 ? ` (attempt ${attempt})` : '';
    let message = `Stage ${state}${attemptSuffix}`;
    if (state === 'succeeded' || state === 'completed') {
      message = `Completed${attemptSuffix}`;
    } else if (state === 'failed') {
      message = `Failed${attemptSuffix}`;
    } else if (state === 'running') {
      message = `Started${attemptSuffix}`;
    } else if (state === 'waiting' || state === 'blocked') {
      message = `Waiting${attemptSuffix}`;
    } else if (state === 'cancelled') {
      message = `Cancelled${attemptSuffix}`;
    }
    events.push({
      id: `${id}:state:${state}:${attempt}:${updatedAt}`,
      timestamp: updatedAt,
      type: state === 'running' || state === 'queued' ? 'stage-start' : 'stage-end',
      stageId: id,
      message,
    });
    const reasonCode = asString(stage['reasonCode']);
    if (reasonCode && reasonCode !== 'none') {
      events.push({
        id: `${id}:reason:${reasonCode}:${updatedAt}`,
        timestamp: updatedAt,
        type: reasonCode === 'stage-failed' || reasonCode.includes('artifact') ? 'verification' : 'rework',
        stageId: id,
        message: translateReasonCode(reasonCode),
      });
    }
  }

  for (const action of actions) {
    const requestId = asString(action.requestId);
    if (!requestId) {
      continue;
    }
    const createdAt = asString(action.createdAt) ?? runCreated ?? new Date(0).toISOString();
    const question = asString(action.question) ?? requestId;
    events.push({
      id: `${requestId}:request`,
      timestamp: createdAt,
      type: 'action-request',
      stageId: asString(action.stageId),
      message: `${asString(action.kind) ?? 'action'} request: ${question}`,
    });
    const { decision, decidedAt, message } = extractDecision(action);
    const status = normalizeActionStatus(action);
    if (decision || status === 'answered' || status === 'consumed') {
      const ts = decidedAt ?? createdAt;
      const decisionText = decision ?? 'recorded';
      const suffix = message ? ` — ${message}` : '';
      const consumption =
        status === 'consumed' ? ' (consumed; replay refused)' : status === 'answered' ? ' (answered; resume to consume)' : '';
      events.push({
        id: `${requestId}:decision:${status}`,
        timestamp: ts,
        type: 'action-response',
        stageId: asString(action.stageId),
        message: `Decision ${decisionText}${suffix}${consumption}`,
      });
    }
  }

  const reasonCode = asString(diagnosis['reasonCode']);
  const summary = asString(diagnosis['summary']);
  const diagStage = asString(diagnosis['stageId']);
  if (reasonCode && reasonCode !== 'none') {
    const updatedAt = asString(run['updatedAt']) ?? runCreated ?? new Date(0).toISOString();
    events.push({
      id: `${runId}:diagnosis:${reasonCode}`,
      timestamp: updatedAt,
      type: reasonCode === 'human-changes-requested' ? 'rework' : reasonCode.includes('approval') || reasonCode.includes('input') ? 'action-request' : 'verification',
      stageId: diagStage,
      message: summary ?? translateReasonCode(reasonCode),
    });
  }

  return events.sort((a, b) => {
    const byTime = a.timestamp.localeCompare(b.timestamp);
    return byTime !== 0 ? byTime : a.id.localeCompare(b.id);
  });
}

function buildActions(actions: readonly RunActionRow[], runState: string | null): ActionDetail[] {
  const terminal = runState ? TERMINAL_STATES.has(runState) : false;
  return actions
    .map((raw): ActionDetail | null => {
      const requestId = asString(raw.requestId);
      if (!requestId) {
        return null;
      }
      const status = normalizeActionStatus(raw);
      const { decision, decidedAt, message } = extractDecision(raw);
      const choices = Array.isArray(raw.choices) ? raw.choices.filter((c): c is string => typeof c === 'string') : ['approve', 'request-changes', 'cancel', 'answer'];
      let enabled = status === 'outstanding' && !terminal;
      let disabledReason: string | null = null;
      if (terminal) {
        enabled = false;
        disabledReason = `Run is ${runState}; action responses are closed`;
      } else if (status === 'consumed') {
        enabled = false;
        disabledReason = 'Decision already consumed; replay is refused';
      } else if (status === 'answered') {
        enabled = false;
        disabledReason = 'Decision already persisted; resume to consume it once';
      } else if (status === 'cancelled') {
        enabled = false;
        disabledReason = 'Request was cancelled';
      }
      return {
        requestId,
        kind: asString(raw.kind) ?? 'action',
        stageId: asString(raw.stageId),
        question: asString(raw.question) ?? requestId,
        status,
        choices,
        decision,
        decidedAt,
        message,
        enabled,
        disabledReason,
      };
    })
    .filter((row): row is ActionDetail => row !== null);
}

function buildOperatorNext(
  nextAction: unknown,
  diagnosis: Record<string, unknown>,
  actions: readonly ActionDetail[],
  runState: string | null,
): OperatorNext {
  const parsed = parseNextActionArgv(nextAction);
  const reasonCode = asString(diagnosis['reasonCode']);
  const summary = asString(diagnosis['summary']);
  const requestId = asString(diagnosis['requestId']);
  const stageId = asString(diagnosis['stageId']);
  const outstanding = actions.filter((a) => a.status === 'outstanding');
  const answered = actions.filter((a) => a.status === 'answered');
  const terminal = runState ? TERMINAL_STATES.has(runState) : false;

  let kind = parsed.kind;
  let label = parsed.label;
  let description = summary ?? translateReasonCode(reasonCode);
  let enabled = true;
  let disabledReason: string | null = null;
  let resetStageId = parsed.resetStageId;

  if (kind === 'none' && outstanding.length > 0) {
    kind = 'respond';
    label = 'Respond to outstanding operator request';
    description = outstanding[0]!.question;
  } else if (kind === 'none' && answered.length > 0 && (runState === 'waiting' || runState === 'blocked')) {
    kind = 'resume';
    label = 'Resume to consume the persisted decision';
    description = summary ?? 'A decision is recorded; resume injects it once';
  } else if (kind === 'none' && reasonCode === 'human-changes-requested') {
    kind = 'reset';
    label = 'Reset the changes target, then resume';
    description = summary ?? translateReasonCode(reasonCode);
  }

  if (terminal) {
    enabled = false;
    disabledReason = `Run is ${runState}; no further operator action`;
    if (kind === 'none') {
      label = runState === 'succeeded' ? 'Run succeeded' : `Run ${runState}`;
    }
  } else if (kind === 'respond') {
    if (outstanding.length === 0) {
      enabled = false;
      disabledReason = 'No outstanding operator request to answer';
    }
  } else if (kind === 'resume') {
    if (outstanding.length > 0) {
      enabled = false;
      disabledReason = 'Answer the outstanding request before resume';
    } else if (!['waiting', 'blocked', 'paused', 'failed', 'stale'].includes(runState ?? '')) {
      enabled = false;
      disabledReason = `Resume is not available while the run is ${runState ?? 'unknown'}`;
    }
  } else if (kind === 'reset') {
    if (!resetStageId) {
      // Infer from argv-less diagnosis text or approval changesTarget on stage evidence.
      const match = (summary ?? '').match(/reset\s+([a-z0-9-]+)/i);
      resetStageId = match?.[1] ?? null;
    }
    if (!resetStageId) {
      enabled = false;
      disabledReason = 'Reset requires a changesTarget stage id';
    } else if (outstanding.length > 0) {
      enabled = false;
      disabledReason = 'Finish or cancel outstanding requests before reset';
    }
  } else if (kind === 'none') {
    enabled = false;
    disabledReason = null;
  }

  return {
    kind,
    label,
    description,
    enabled,
    disabledReason,
    stageId,
    requestId,
    resetStageId,
    argv: parsed.argv,
  };
}

function normalizeActionsInput(raw: unknown): RunActionRow[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw
    .map((entry): RunActionRow | null => {
      const rec = asRecord(entry);
      if (!rec) {
        return null;
      }
      const requestId = asString(rec['requestId']) ?? asString(rec['id']);
      if (!requestId) {
        return null;
      }
      return {
        requestId,
        kind: asString(rec['kind']) ?? asString(rec['type']) ?? 'action',
        stageId: asString(rec['stageId']),
        question: asString(rec['question']) ?? asString(rec['description']),
        status: asString(rec['status']),
        choices: Array.isArray(rec['choices']) ? (rec['choices'] as string[]) : null,
        decision: rec['decision'],
        consumed: rec['consumed'],
        createdAt: asString(rec['createdAt']),
        decidedAt: asString(rec['decidedAt']),
        message: asString(rec['message']),
      };
    })
    .filter((row): row is RunActionRow => row !== null);
}

/**
 * Enrich CLI status + actions list into a dashboard detail payload.
 * Preserves the original status fields and adds `detail`.
 */
export function enrichWorkflowRunDetail(status: unknown, actionsRaw: unknown = []): EnrichedWorkflowRunDetail {
  const root = asRecord(status) ?? {};
  const run = asRecord(root['run']) ?? {};
  const diagnosis = asRecord(root['diagnosis']) ?? {};
  const stages = Array.isArray(root['stages'])
    ? root['stages'].map((s) => asRecord(s) ?? {}).filter((s) => Object.keys(s).length > 0)
    : [];
  const nextAction = root['nextAction'] ?? null;
  const runState = asString(run['state']) ?? asString(diagnosis['state']);
  const actionRows = normalizeActionsInput(actionsRaw);
  const parsedNext = parseNextActionArgv(nextAction);
  const actionDetails = buildActions(actionRows, runState);
  const operatorNext = buildOperatorNext(nextAction, diagnosis, actionDetails, runState);
  const stageMap = buildStageMap(stages, diagnosis, operatorNext.kind !== 'none' ? operatorNext.kind : parsedNext.kind);
  const timeline = buildTimeline(run, stages, diagnosis, actionRows);

  return {
    schemaVersion: typeof root['schemaVersion'] === 'number' ? root['schemaVersion'] : 1,
    run,
    stages,
    diagnosis,
    nextAction,
    detail: {
      stageMap,
      timeline,
      operatorNext,
      actions: actionDetails,
    },
  };
}
