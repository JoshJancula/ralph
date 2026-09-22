/**
 * The composition-root half of the assistant's tool surface: tools.ts
 * declares what the tools are; this factory is the only place that knows how
 * to answer them.
 *
 * It implements every `read` and `draft` tool. It does NOT implement the
 * `propose` tools: a proposal is confirmed in the UI and committed through
 * the existing guarded REST routes (POST /api/tasks, /api/schedules,
 * /api/workflows), so their validation is never duplicated here. The two
 * legacy mutations (`start_workflow`, `cancel_run`) remain executable through
 * the explicit `approvedAction` path that predates proposals.
 */
import { randomBytes } from 'node:crypto';
import { promises as fs } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  cancelRun,
  installedRuntimes,
  listPlans,
  listRuns,
  listWorkflows,
  inspectWorkflow,
  runStatus,
  startWorkflowDetached,
  RalphCliError,
  type RunOptions,
} from '../ralph-cli';
import { pollForRunId, startRunIdTimeoutMs, modelFromWire } from '../workflow-api';
import { emitWorkflowFrontmatter, WorkflowFrontmatterError } from '../workflow-frontmatter';
import { formatValidationIssues, validateWorkflowModel } from '../workflow-frontmatter-validate';
import {
  DEFAULT_TASK_STATUSES,
  TEMPLATES,
  allTasks,
  previewCron,
  readStore,
  validCron,
  validZone,
  type Task,
} from '../task-schedule-api';
import { findAssistantTool, validateToolArguments, type AssistantToolName } from './tools';
import type { AssistantToolCall, AssistantToolExecutorPort } from './ports';

export class AssistantToolValidationError extends Error {}

const RUNS_LIMIT = 20;
/** Bounds each tool result so one huge list cannot blow up the prompt. */
const SNAPSHOT_BYTE_CAP = 20_000;

export interface AssistantWorkspaceContext {
  readonly projectRoot: string;
  readonly workspaceRoot: string;
}

function truncateForSnapshot(value: unknown): unknown {
  const text = JSON.stringify(value);
  if (text === undefined || text.length <= SNAPSHOT_BYTE_CAP) {
    return value;
  }
  return { truncated: true, note: `Result exceeded ${SNAPSHOT_BYTE_CAP} bytes and was cut off.`, preview: text.slice(0, SNAPSHOT_BYTE_CAP) };
}

function str(args: Readonly<Record<string, unknown>>, key: string): string {
  const value = args[key];
  return typeof value === 'string' ? value : '';
}

/** Board-relevant fields only: full attempt histories are large and rarely what the model needs. */
function summarizeTask(task: Task): Record<string, unknown> {
  const latest = task.attempts?.[task.attempts.length - 1];
  return {
    id: task.id,
    title: task.title,
    status: task.status,
    workflowId: task.workflowId,
    scope: task.scope,
    ...(task.description ? { description: task.description.slice(0, 500) } : {}),
    ...(task.acceptanceCriteria ? { acceptanceCriteria: task.acceptanceCriteria.slice(0, 500) } : {}),
    ...(task.autoRecommendation ? { autoRecommendation: task.autoRecommendation } : {}),
    ...(task.targetWorkspaceRoot ? { targetWorkspaceRoot: task.targetWorkspaceRoot } : {}),
    ...(task.failureCount ? { failureCount: task.failureCount } : {}),
    attemptCount: task.attempts?.length ?? 0,
    ...(latest
      ? {
          latestAttempt: {
            status: latest.status,
            startedAt: latest.startedAt,
            ...(latest.runId ? { runId: latest.runId } : {}),
            ...(latest.outcome ? { outcome: latest.outcome } : {}),
            ...(latest.summary ? { summary: latest.summary.slice(0, 300) } : {}),
            ...(latest.error ? { error: latest.error.slice(0, 300) } : {}),
          },
        }
      : {}),
  };
}

export function createAssistantToolExecutor(context: AssistantWorkspaceContext): AssistantToolExecutorPort {
  const options: RunOptions = {
    cwd: context.projectRoot,
    projectRoot: context.projectRoot,
    workspaceRoot: context.workspaceRoot,
  };
  const roots = { projectRoot: context.projectRoot, workspaceRoot: context.workspaceRoot };

  /**
   * Validates a drafted workflow without writing into any workflow scope: the
   * temp file lives in the OS temp dir, so a failed draft cannot leave a
   * broken file where Ralph would resolve it.
   */
  async function validateWorkflowDraft(model: unknown): Promise<unknown> {
    let content: string;
    try {
      const parsed = modelFromWire(model as Record<string, unknown>, '', '\n');
      const issues = validateWorkflowModel(parsed);
      if (issues.length > 0) {
        return { valid: false, stage: 'model', diagnostics: formatValidationIssues(issues) };
      }
      content = emitWorkflowFrontmatter(parsed);
    } catch (error: unknown) {
      return {
        valid: false,
        stage: 'model',
        diagnostics: error instanceof WorkflowFrontmatterError ? error.message : 'Invalid workflow model',
      };
    }

    const dir = await fs.mkdtemp(join(tmpdir(), 'ralph-assistant-draft-'));
    const file = join(dir, 'draft.workflow.md');
    try {
      await fs.writeFile(file, content, 'utf8');
      const inspected = await inspectWorkflow({ file }, 'json', options);
      let mermaid = '';
      try {
        mermaid = await inspectWorkflow({ file }, 'mermaid', options);
      } catch {
        // A graph is a nicety; a valid workflow without one is still valid.
      }
      return truncateForSnapshot({ valid: true, frontmatter: content, inspect: JSON.parse(inspected), ...(mermaid ? { mermaid } : {}) });
    } catch (error: unknown) {
      const diagnostics =
        error instanceof RalphCliError ? error.stderr || error.message : error instanceof Error ? error.message : 'validation failed';
      return { valid: false, stage: 'inspect', diagnostics, frontmatter: content };
    } finally {
      await fs.rm(dir, { recursive: true, force: true }).catch(() => undefined);
    }
  }

  async function execute(call: AssistantToolCall): Promise<unknown> {
    const tool = findAssistantTool(call.name);
    if (!tool) {
      throw new AssistantToolValidationError(`Unknown assistant tool: ${call.name}`);
    }
    const invalid = validateToolArguments(tool, call.arguments);
    if (invalid) {
      throw new AssistantToolValidationError(invalid);
    }

    switch (call.name as AssistantToolName) {
      // ----- read -----
      case 'list_workflows':
        return truncateForSnapshot(await listWorkflows(options));
      case 'get_workflow': {
        const workflowId = str(call.arguments, 'workflowId');
        const rows = await listWorkflows(options);
        const row = rows.find((entry) => entry.id === workflowId);
        if (!row) {
          return { error: `Workflow "${workflowId}" not found` };
        }
        const inspectJson = await inspectWorkflow({ id: workflowId }, 'json', options);
        return truncateForSnapshot({ id: workflowId, scope: row.scope, overview: row.overview, inspect: JSON.parse(inspectJson) });
      }
      case 'list_runs': {
        const runs = await listRuns({ limit: RUNS_LIMIT }, options);
        return truncateForSnapshot(Array.isArray(runs) ? runs.slice(0, RUNS_LIMIT) : runs);
      }
      case 'get_run_status':
        return truncateForSnapshot(await runStatus(str(call.arguments, 'runId'), options));
      case 'list_plans':
        return truncateForSnapshot(await listPlans(options));
      case 'list_tasks':
        return truncateForSnapshot((await allTasks(roots)).map(summarizeTask));
      case 'list_task_statuses': {
        const store = await readStore(roots, 'project');
        return store.taskStatuses?.length ? store.taskStatuses : DEFAULT_TASK_STATUSES;
      }
      case 'list_schedules': {
        const [project, global] = await Promise.all([readStore(roots, 'project'), readStore(roots, 'global')]);
        return truncateForSnapshot(
          [...project.schedules, ...global.schedules].map((schedule) => ({
            id: schedule.id,
            name: schedule.name,
            scope: schedule.scope,
            cron: schedule.cron,
            timezone: schedule.timezone,
            enabled: schedule.enabled,
            ...(schedule.workflowId ? { workflowId: schedule.workflowId } : {}),
            ...(schedule.worker ? { worker: schedule.worker } : {}),
            ...(schedule.lastError ? { lastError: schedule.lastError } : {}),
            ...(schedule.consecutiveFailures ? { consecutiveFailures: schedule.consecutiveFailures } : {}),
            upcoming: previewCron(schedule.cron, schedule.timezone, 3),
          })),
        );
      }
      case 'list_workflow_templates':
        return TEMPLATES.map(([id, category, purpose, outputs]) => ({ id, category, purpose, outputs }));
      case 'list_runtimes': {
        const installed = await installedRuntimes();
        return Object.entries(installed).map(([id, isInstalled]) => ({ id, installed: isInstalled }));
      }

      // ----- draft (write-free) -----
      case 'preview_cron': {
        const cron = str(call.arguments, 'cron');
        const timezone = str(call.arguments, 'timezone');
        if (!validCron(cron)) {
          return { valid: false, error: 'cron must be five fields, for example "0 9 * * 1-5"' };
        }
        if (!validZone(timezone)) {
          return { valid: false, error: `"${timezone}" is not a valid IANA timezone` };
        }
        return { valid: true, cron, timezone, upcoming: previewCron(cron, timezone, 5) };
      }
      case 'validate_workflow_draft':
        return validateWorkflowDraft(call.arguments['model']);

      // ----- legacy explicit-approval mutations -----
      case 'start_workflow': {
        const workflowId = str(call.arguments, 'workflowId');
        const task = str(call.arguments, 'task');
        const logDir = join(context.workspaceRoot, 'artifacts', 'dashboard-runs');
        await fs.mkdir(logDir, { recursive: true });
        const logPath = join(logDir, `${workflowId}-${Date.now()}-${randomBytes(4).toString('hex')}.log`);
        startWorkflowDetached({ id: workflowId, task }, logPath, options);
        const runId = await pollForRunId(logPath, startRunIdTimeoutMs());
        return runId ? { runId, status: 'started' } : { status: 'pending', logPath };
      }
      case 'cancel_run': {
        const runId = str(call.arguments, 'runId');
        await cancelRun(runId, options);
        return { runId, cancelled: true };
      }

      default:
        throw new AssistantToolValidationError(
          `${call.name} is proposed in the dashboard and committed through its own API route, not executed here`,
        );
    }
  }

  return { execute };
}
