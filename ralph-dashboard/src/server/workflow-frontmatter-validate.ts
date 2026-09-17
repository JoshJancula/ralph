/**
 * Local, safe validation messages that mirror plan-todo / `ralph workflow
 * inspect` refusals for the structured editor. The server still runs inspect
 * as the authority on save; these messages exist so the UI can surface exact
 * wording before a round-trip.
 */
import type {
  OrdinaryStageModel,
  StageModel,
  SupervisorStageModel,
  WorkflowFrontmatterModel,
} from './workflow-frontmatter';
import { SUPERVISOR_FORBIDDEN_AGENT_FIELDS } from './workflow-frontmatter';

const STAGE_ID_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const WORKSPACE_MODES = new Set(['shared', 'snapshot', 'worktree']);
const GIT_ACCESS = new Set(['inherit', 'off', 'on']);
const PUBLISH_MODES = new Set(['manual', 'on-verified']);
const PLANNER_OUTPUT_MODES = new Set(['plan-file']);
const PLANNER_HARD_MAX_TODOS = 200;
const SESSION_STRATEGIES = new Set(['fresh', 'resume', 'reset', 'compact']);

export interface WorkflowValidationIssue {
  readonly path: string;
  readonly message: string;
}

function stagePrefix(stage: StageModel, ordinal: number): string {
  return stage.id ? `stage ${stage.id}` : `stage[${ordinal}]`;
}

function validateSupervisorForbidden(stage: SupervisorStageModel, prefix: string, issues: WorkflowValidationIssue[]): void {
  const record = stage as unknown as Record<string, unknown>;
  for (const field of SUPERVISOR_FORBIDDEN_AGENT_FIELDS) {
    if (field === 'writeScopes' || field === 'loopCheck') {
      continue;
    }
    if (record[field] !== undefined && record[field] !== null && record[field] !== '') {
      issues.push({
        path: `${prefix}.${field}`,
        message: `${prefix} ${field}: ${stage.type} nodes do not take ${field}`,
      });
    }
  }
  if (stage.type === 'approval') {
    if (stage.workspaceMode) {
      issues.push({
        path: `${prefix}.workspaceMode`,
        message: `${prefix} workspaceMode: approval nodes do not take workspaceMode`,
      });
    }
    if (stage.profile) {
      issues.push({
        path: `${prefix}.profile`,
        message: `${prefix} profile: approval nodes do not take profile`,
      });
    }
    if (!stage.question || !stage.question.trim()) {
      issues.push({
        path: `${prefix}.question`,
        message: `${prefix} question: required non-empty text`,
      });
    }
  }
  if (stage.type === 'integrate' && stage.workspaceMode && !WORKSPACE_MODES.has(stage.workspaceMode)) {
    issues.push({
      path: `${prefix}.workspaceMode`,
      message: `${prefix} workspaceMode: must be shared, snapshot, or worktree`,
    });
  }
  if (stage.type === 'integrate' && (stage.workspaceMode ?? 'shared') === 'shared') {
    issues.push({
      path: `${prefix}.workspaceMode`,
      message: `${prefix} workspaceMode: integrate nodes require snapshot or worktree`,
    });
  }
}

function validateOrdinary(stage: OrdinaryStageModel, prefix: string, issues: WorkflowValidationIssue[]): void {
  if (stage.sessionStrategy && !SESSION_STRATEGIES.has(stage.sessionStrategy)) {
    issues.push({
      path: `${prefix}.sessionStrategy`,
      message: `${prefix} sessionStrategy: must be fresh, resume, reset, or compact`,
    });
  }
  if (stage.workspaceMode && !WORKSPACE_MODES.has(stage.workspaceMode)) {
    issues.push({
      path: `${prefix}.workspaceMode`,
      message: `${prefix} workspaceMode: must be shared, snapshot, or worktree`,
    });
  }
  if (stage.agentGitAccess && !GIT_ACCESS.has(stage.agentGitAccess)) {
    issues.push({
      path: `${prefix}.agentGitAccess`,
      message: `${prefix} agentGitAccess: must be inherit, off, or on`,
    });
  }
  if (stage.planner) {
    if (!PLANNER_OUTPUT_MODES.has(stage.planner.outputMode)) {
      issues.push({
        path: `${prefix}.planner.outputMode`,
        message: `${prefix} planner.outputMode: must be plan-file`,
      });
    }
    if (stage.planner.maxTodos !== undefined) {
      if (!Number.isInteger(stage.planner.maxTodos) || stage.planner.maxTodos < 1 || stage.planner.maxTodos > PLANNER_HARD_MAX_TODOS) {
        issues.push({
          path: `${prefix}.planner.maxTodos`,
          message: `${prefix} planner.maxTodos: must be an integer between 1 and ${PLANNER_HARD_MAX_TODOS}`,
        });
      }
    }
  }
  if (stage.planFrom && stage.planner) {
    issues.push({
      path: `${prefix}.planFrom`,
      message: `${prefix} planFrom: mutually exclusive with planner`,
    });
  }
  if (stage.instructions !== undefined && !stage.instructions.trim()) {
    issues.push({
      path: `${prefix}.instructions`,
      message: `${prefix} instructions: must be non-empty text`,
    });
  }
}

/**
 * Returns structured validation issues using wording aligned with plan-todo.
 * Empty array means locally clean; inspect may still refuse for cross-stage rules.
 */
export function validateWorkflowModel(model: WorkflowFrontmatterModel): readonly WorkflowValidationIssue[] {
  const issues: WorkflowValidationIssue[] = [];

  if (model.mode && model.mode !== 'sequential' && model.mode !== 'dependency') {
    issues.push({ path: 'mode', message: `mode: invalid mode ${JSON.stringify(model.mode)}` });
  }
  if (model.publishMode && !PUBLISH_MODES.has(model.publishMode)) {
    issues.push({ path: 'pipeline.publishMode', message: 'invalid publishMode value' });
  }
  if (model.maxReworkIterations !== undefined) {
    if (!Number.isInteger(model.maxReworkIterations) || model.maxReworkIterations < 1 || model.maxReworkIterations > 5) {
      issues.push({
        path: 'pipeline.maxReworkIterations',
        message: 'maxReworkIterations must be an integer between 1 and 5',
      });
    }
  }
  if (model.planInput) {
    if (!model.planInput.stage) {
      issues.push({ path: 'planInput.stage', message: 'planInput.stage: required' });
    } else if (!model.stages.some((stage) => stage.id === model.planInput!.stage)) {
      issues.push({
        path: 'planInput.stage',
        message: `planInput.stage: unknown stage ${JSON.stringify(model.planInput.stage)}`,
      });
    }
  }

  const ids = new Set<string>();
  model.stages.forEach((stage, ordinal) => {
    const prefix = stagePrefix(stage, ordinal);
    if (!stage.id) {
      issues.push({ path: `${prefix}.id`, message: `${prefix} id: missing stage id` });
    } else if (!STAGE_ID_RE.test(stage.id)) {
      issues.push({ path: `${prefix}.id`, message: `${prefix} id: invalid stage id format` });
    } else if (ids.has(stage.id)) {
      issues.push({ path: `${prefix}.id`, message: `${prefix} id: duplicate stage id` });
    } else {
      ids.add(stage.id);
    }

    if (stage.kind === 'supervisor') {
      validateSupervisorForbidden(stage, prefix, issues);
    } else {
      validateOrdinary(stage, prefix, issues);
    }
  });

  if (model.unsupportedKeys.length > 0) {
    issues.push({
      path: 'unsupportedKeys',
      message: `Cannot emit structured frontmatter for a model with unsupported keys: ${model.unsupportedKeys.join(', ')}`,
    });
  }

  return issues;
}

export function formatValidationIssues(issues: readonly WorkflowValidationIssue[]): string {
  return issues.map((issue) => issue.message).join('\n');
}
