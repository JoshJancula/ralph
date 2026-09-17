/** Dashboard-owned task queue and lightweight cron scheduler.  These records
 * intentionally live outside Ralph's workflow registry: Ralph remains the
 * authority for runs while the dashboard owns operational intent.
 *
 * Division of responsibility: the dashboard decides which task runs and what
 * status it lands in; the agent only executes and reports back through a
 * result file (see renderBrief). Agents never mutate the queue directly.
 *
 * Two schedule shapes exist:
 * - a workflow schedule starts one workflow with fixed instructions;
 * - the built-in task worker pulls ready tasks and runs each with the task's own
 *   workflow. Tasks with no workflow (or `auto`) get a triage routing pass first
 *   and return to ready with the recommended workflow for a later pass. */
import { randomUUID } from 'node:crypto';
import { existsSync, promises as fs } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import type { Express, Request, RequestHandler, Response } from 'express';
import { findDashboardRoots, type DashboardRoots } from '../paths';
import { getMergedWorkspaceAllowlist } from './dashboard-api';
import { resolveDashboardRootsForWorkspaceRoot } from './dashboard-workspace-resolve';
import {
  inspectWorkflow,
  listRuns as listWorkflowRuns,
  listWorkflows,
  RalphCliError,
  runPlanDetached,
  runStatus,
  startWorkflowDetached,
  type RunOptions,
} from './ralph-cli';
import { writeGuard } from './write-guard';

type TaskStatus = string;
type Scope = 'project' | 'global';
type InstalledWorkflows = Awaited<ReturnType<typeof listWorkflows>>;
export type AttemptStatus = 'launching' | 'running' | 'completed' | 'failed' | 'cancelled' | 'blocked';
export type ResultOutcome = 'done' | 'blocked' | 'needs_human' | 'missing';
export type FollowUp = { title: string; description: string };
export type LeafPlan = { path: string; title: string; updatedAt: string };
export type TaskAttempt = { id: string; startedAt: string; endedAt?: string; runId?: string; pid?: number; executionKind?: 'workflow' | 'leaf-plan'; planPath?: string; workflowId?: string; autoRoute?: boolean; projectRoot?: string; workspaceRoot?: string; logPath: string; briefPath?: string; resultPath?: string; snapshotPath?: string; scheduleId?: string; /** Status the task was pulled from; retries and routing return it there. */ sourceStatus?: string; status: AttemptStatus; error?: string; outcome?: ResultOutcome; summary?: string };
export type Task = { id: string; title: string; description?: string; acceptanceCriteria?: string; workflowId: string; /** Empty omits flags; Ralph uses workflow defaults. */ runtime?: string; model?: string; leafPlan?: LeafPlan; autoRecommendation?: string; scope: Scope; targetMode?: 'registered' | 'new-project' | 'global'; targetWorkspaceRoot?: string; projectPath?: string; parentTaskId?: string; status: TaskStatus; failureCount?: number; createdAt: string; updatedAt: string; attempts: TaskAttempt[] };
/** `one` runs a single task at a time; `all` keeps up to `maxConcurrent` tasks running. `status` is the board column it pulls from. */
export type TaskWorker = { mode: 'one' | 'all'; maxConcurrent: number; status: string };
export type Schedule = { id: string; name: string; scope: Scope; workflowId: string; cron: string; timezone: string; enabled: boolean; brief?: string; worker?: TaskWorker; targetWorkspaceRoot?: string; lastRunAt?: string; nextRunAt?: string; activeTaskIds?: string[]; activeAttempt?: TaskAttempt; consecutiveFailures?: number; lastError?: string };
export type SchedulePatch = Partial<Omit<Schedule, 'worker'>> & { worker?: TaskWorker | null };
type Store = { tasks: Task[]; schedules: Schedule[]; taskStatuses?: string[] };
export type AttemptPoll = { runId?: string; status: AttemptStatus; error?: string; outcome?: ResultOutcome; summary?: string; followUps?: FollowUp[]; recommendedWorkflow?: string | null };

export const DEFAULT_TASK_STATUSES = ['backlog', 'ready', 'in_progress', 'review', 'blocked', 'completed', 'discarded'];
/** Automatic retries a task gets before it is parked in blocked for a human. */
export const MAX_TASK_FAILURES = 3;
/** Consecutive failed runs after which a schedule pauses itself. */
export const MAX_CONSECUTIVE_SCHEDULE_FAILURES = 3;
export const DEFAULT_WORKER_CONCURRENCY = 3;
/** Parallel runs share the project's working tree unless the workflow isolates itself, so "all" stays bounded. */
export const MAX_WORKER_CONCURRENCY = 10;
export const DEFAULT_WORKER_STATUS = 'ready';
/** Statuses a worker may never pull from: running work, the columns the worker itself parks results
 * and failures in (pulling those would re-run finished work or retry forever), and closed work. */
export const RESERVED_WORKER_STATUSES: readonly string[] = ['in_progress', 'review', 'blocked', 'completed', 'discarded'];
const MAX_FOLLOW_UPS = 10;
/** Launches with no pid (legacy records) are declared dead after this long without a Run line. */
const LAUNCH_STALE_MS = 10 * 60_000;
const ACTIVE: ReadonlySet<AttemptStatus> = new Set(['launching', 'running']);
/** Tasks assigned the pseudo-workflow `auto` (or no workflow) first run `triage`, which recommends a delivery workflow. */
export const AUTO_WORKFLOW = 'auto';
const TRIAGE_WORKFLOW = 'triage';

const CRON_FIELD = /^(\*|\*\/\d+|\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*)$/;
const schedulerTimers = new Map<string, NodeJS.Timeout>();
export const TEMPLATES = [
  ['task-loopback-delivery', 'Software development', 'A durable task intake, implementation, and evidence handoff loop.', 'Task snapshot and implementation handoff.'],
  ['market-pulse', 'Trade analysis', 'Research-only market pulse. Does not execute trades or broker actions.', 'Analysis brief.'],
  ['market-thesis', 'Trade analysis', 'Research-only market thesis. Does not execute trades or broker actions.', 'Thesis and risks.'],
  ['watchlist-review', 'Trade analysis', 'Research-only watchlist review. Does not execute trades or broker actions.', 'Watchlist review.'],
  ['email-digest', 'Assistants', 'Connector-ready digest; requires the user’s configured mail connector.', 'Digest handoff.'],
  ['research-brief', 'Assistants', 'Connector-ready research brief; requires the user’s configured research connector.', 'Research brief.'],
] as const;
function templateContent(id: string, overview: string): string { return `---\nname: ${id}\noverview: ${overview}\nkind: workflow\nmode: sequential\npipeline:\n  maxParallel: 1\n  stages:\n    - id: deliver\n      instructions: |\n        Complete {{TASK}} within the stated scope. Record evidence, limitations, and next steps in .ralph-workspace/artifacts/{{ARTIFACT_NS}}/${id}-handoff.md.\n      produces:\n        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/${id}-handoff.md\n          required: true\n---\n`; }

function jsonError(res: Response, status: number, error: string): void { res.status(status).json({ error }); }
function context(req: Request): DashboardRoots { return (req as Request & { dashboardRoots?: DashboardRoots }).dashboardRoots!; }
function options(roots: DashboardRoots): RunOptions { return { cwd: roots.projectRoot, projectRoot: roots.projectRoot, workspaceRoot: roots.workspaceRoot }; }
function globalDir(): string { return join(process.env['XDG_CONFIG_HOME']?.trim() || join(homedir(), '.config'), 'ralph', 'dashboard'); }
function globalStoreFile(): string { return join(globalDir(), 'tasks-schedules.json'); }
function projectStoreFile(workspaceRoot: string): string { return join(workspaceRoot, 'dashboard', 'tasks-schedules.json'); }
function storePath(roots: DashboardRoots, scope: Scope): string { return scope === 'global' ? globalStoreFile() : projectStoreFile(roots.workspaceRoot); }
function sameRoot(a: string | undefined, b: string | undefined): boolean { return !!a && !!b && resolve(a) === resolve(b); }
/** The workflow a task actually runs: its assignment, or auto routing when it has none. */
export function effectiveWorkflow(task: Pick<Task, 'workflowId'>): string { return task.workflowId?.trim() || AUTO_WORKFLOW; }

function managedPlanPath(roots: DashboardRoots, taskId: string): string { return join(roots.workspaceRoot, 'plans', `${taskId}.plan.md`); }
function classicPlan(title: string, task: Task): string {
  return `# ${title}\n\n## Task context\n\n${task.description?.trim() || task.title}\n\nAcceptance criteria:\n${task.acceptanceCriteria?.trim() || '(none provided)'}\n\n## TODOs\n\n- [ ] Investigate the task and identify the files and tests involved.\n- [ ] Implement the requested change with focused verification.\n- [ ] Run the relevant verification and record the result.\n`;
}
function hasOpenTodos(content: string): boolean { return /^\s*-\s+\[ \]/m.test(content); }

/** Same slug rules the task-status editor applies, so "To do" matches the stored `to_do` column. */
function statusSlug(value: string): string { return value.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, ''); }

export function normalizeWorker(raw: unknown): TaskWorker {
  const value = raw && typeof raw === 'object' ? raw as Record<string, unknown> : {};
  const requested = Math.floor(Number(value['maxConcurrent']));
  const status = typeof value['status'] === 'string' ? statusSlug(value['status']) : '';
  return { mode: value['mode'] === 'all' ? 'all' : 'one', maxConcurrent: Number.isFinite(requested) && requested >= 1 ? Math.min(requested, MAX_WORKER_CONCURRENCY) : DEFAULT_WORKER_CONCURRENCY, status: status || DEFAULT_WORKER_STATUS };
}

export function workerStatusError(status: string): string | null {
  return RESERVED_WORKER_STATUSES.includes(status) ? `A task worker cannot pull from "${status}". Choose a status tasks wait in before work starts, such as ready.` : null;
}

/** Upgrades legacy schedule records (kind/workerPolicy/concurrency/includeReadyTask) to the current shape. */
export function normalizeSchedule(raw: Record<string, unknown>): Schedule {
  const { kind, workerPolicy, concurrency, includeReadyTask, ...rest } = raw as Record<string, unknown>;
  const schedule = rest as unknown as Schedule;
  if (schedule.worker) {
    schedule.worker = normalizeWorker(schedule.worker);
  } else if (kind === 'task-worker' || includeReadyTask === true) {
    schedule.worker = normalizeWorker({ mode: workerPolicy === 'fill-concurrency' ? 'all' : 'one', maxConcurrent: concurrency, status: DEFAULT_WORKER_STATUS });
    schedule.workflowId = '';
  }
  return schedule;
}
async function readStoreFile(path: string): Promise<Store> {
  try {
    const x = JSON.parse(await fs.readFile(path, 'utf8'));
    return {
      tasks: Array.isArray(x.tasks) ? x.tasks : [],
      schedules: Array.isArray(x.schedules) ? x.schedules.map(normalizeSchedule) : [],
      ...(Array.isArray(x.taskStatuses) ? { taskStatuses: x.taskStatuses.filter((s: unknown) => typeof s === 'string') } : {}),
    };
  } catch { return { tasks: [], schedules: [] }; }
}
export async function readStore(roots: DashboardRoots, scope: Scope): Promise<Store> { return readStoreFile(storePath(roots, scope)); }
async function writeStoreFile(path: string, store: Store): Promise<void> { await fs.mkdir(dirname(path), { recursive: true }); const temp = `${path}.${randomUUID()}.tmp`; await fs.writeFile(temp, JSON.stringify(store, null, 2) + '\n'); await fs.rename(temp, path); }
const storeLocks = new Map<string, Promise<unknown>>();
/** Serializes read-modify-write cycles per store file so the scheduler and API handlers cannot overwrite each other. Never nest calls on the same path. */
async function updateStoreFile<T>(path: string, mutate: (store: Store) => T | Promise<T>): Promise<T> {
  const previous = storeLocks.get(path) ?? Promise.resolve();
  const run = previous.catch(() => undefined).then(async () => { const store = await readStoreFile(path); const result = await mutate(store); await writeStoreFile(path, store); return result; });
  storeLocks.set(path, run.catch(() => undefined));
  return run;
}
function updateStore<T>(roots: DashboardRoots, scope: Scope, mutate: (store: Store) => T | Promise<T>): Promise<T> { return updateStoreFile(storePath(roots, scope), mutate); }

export function validCron(value: unknown): value is string { return typeof value === 'string' && value.trim().split(/\s+/).length === 5 && value.trim().split(/\s+/).every((x) => CRON_FIELD.test(x)); }
export function validZone(value: unknown): value is string { if (typeof value !== 'string' || !value.trim()) return false; try { Intl.DateTimeFormat('en-US', { timeZone: value }); return true; } catch { return false; } }
function cronPartMatches(part: string, value: number): boolean { return part.split(',').some((piece) => { const [range, stepText] = piece.split('/'); const step = stepText ? Number(stepText) : 1; if (!Number.isInteger(step) || step < 1) return false; if (range === '*') return value % step === 0; const [lowText, highText] = range.split('-'); const low = Number(lowText); const high = highText ? Number(highText) : low; return value >= low && value <= high && (value - low) % step === 0; }); }
/** Returns UTC instants that match the cron in its declared IANA timezone. */
export function previewCron(cron: string, timezone: string, count = 3, from = new Date()): string[] { const out: string[] = []; const probe = new Date(from); probe.setUTCSeconds(0, 0); probe.setUTCMinutes(probe.getUTCMinutes() + 1); for (let i = 0; i < 525_960 && out.length < count; i++, probe.setUTCMinutes(probe.getUTCMinutes() + 1)) if (cronDueNow(cron, timezone, probe)) out.push(probe.toISOString()); return out; }
function cronDueNow(cron: string, timezone: string, now = new Date()): boolean { const parts = new Intl.DateTimeFormat('en-US', { timeZone: timezone, weekday: 'short', hour: 'numeric', minute: 'numeric', day: 'numeric', month: 'numeric', hourCycle: 'h23' }).formatToParts(now); const value = (type: string) => Number(parts.find((part) => part.type === type)?.value); const weekday = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'].indexOf(parts.find((part) => part.type === 'weekday')?.value || ''); const [mi, hr, day, mon, dow] = cron.split(/\s+/); return cronPartMatches(mi, value('minute')) && cronPartMatches(hr, value('hour')) && cronPartMatches(day, value('day')) && cronPartMatches(mon, value('month')) && cronPartMatches(dow, weekday); }
const middleware: RequestHandler = async (req, res, next) => { const requested = typeof req.query['workspaceRoot'] === 'string' ? req.query['workspaceRoot'] : undefined; const roots = requested ? resolveDashboardRootsForWorkspaceRoot(requested, await getMergedWorkspaceAllowlist()) : findDashboardRoots(); if (!roots) return jsonError(res, 400, 'invalid workspaceRoot'); (req as Request & { dashboardRoots?: DashboardRoots }).dashboardRoots = roots; next(); };
function scope(body: Record<string, unknown>): Scope { return body['scope'] === 'global' ? 'global' : 'project'; }
export async function allTasks(roots: DashboardRoots): Promise<Task[]> { return [...(await readStore(roots, 'project')).tasks, ...(await readStore(roots, 'global')).tasks]; }
async function isRegisteredWorkspace(workspaceRoot: string): Promise<boolean> { return (await getMergedWorkspaceAllowlist()).some((entry) => sameRoot(entry.workspaceRoot, workspaceRoot)); }

// ---------------------------------------------------------------------------
// Brief and result-file contract
// ---------------------------------------------------------------------------

/** Ralph treats `--plan` files containing checkbox lines as leaf plans. Rewriting
 * `- [ ]` to `* [ ]` keeps the text readable while guaranteeing the file is read
 * as a task description. The leading heading also keeps it from looking like frontmatter. */
export function neutralizePlanSyntax(text: string): string { return text.replace(/^([ \t]*)-([ \t]+\[[ \txX]\])/gm, '$1*$2'); }

/** Delivery runs report an outcome; routing runs (`routeTo` set) report a recommended workflow chosen from `routeTo`. */
export function renderBrief(input: { heading: string; instructions?: string; task?: Task; snapshotPath?: string; resultPath: string; routeTo?: ReadonlyArray<{ id: string; overview?: string }> }): string {
  const sections = [`# ${input.heading}`];
  if (input.instructions?.trim()) sections.push(`## Instructions\n\n${input.instructions.trim()}`);
  if (input.task) {
    const t = input.task;
    const target = t.targetMode === 'new-project' ? `new project at ${t.projectPath || 'unspecified path'}` : t.targetMode === 'global' ? 'global setup' : t.targetWorkspaceRoot || 'current dashboard project';
    sections.push([`## Task ${t.id}`, '', `Title: ${t.title}`, '', `Description:\n${t.description?.trim() || '(none)'}`, '', `Acceptance criteria:\n${t.acceptanceCriteria?.trim() || '(none)'}`, '', `Target: ${target}`, ...(input.snapshotPath ? [`Snapshot: ${input.snapshotPath}`] : [])].join('\n'));
  }
  if (input.routeTo) {
    sections.push([
      '## Routing pass',
      '',
      'This is an Auto routing pass. Recommend exactly one installed delivery workflow for this task; do not implement anything.',
      '',
      `In the stage that makes the final recommendation, also write a JSON file at: ${input.resultPath}`,
      '',
      '{ "recommendedWorkflow": "workflow-id", "summary": "Why this workflow fits and the alternatives lose" }',
      '',
      'recommendedWorkflow must be one of these installed workflows:',
      '',
      ...(input.routeTo.length ? input.routeTo.map((w) => `* ${w.id}${w.overview ? `: ${w.overview}` : ''}`) : ['* (none installed)']),
    ].join('\n'));
  } else {
    sections.push([
      '## Report back',
      '',
      `When you finish, write a JSON file at: ${input.resultPath}`,
      '',
      '{ "outcome": "done", "summary": "What you did and the evidence", "followUps": [{ "title": "Short outcome", "description": "Context" }] }',
      '',
      '* outcome is one of "done", "blocked", or "needs_human".',
      '* Use "done" only when every acceptance criterion is met and verified. Use "blocked" when you cannot proceed, and "needs_human" when a decision or review is required.',
      '* followUps is optional. Each entry becomes a backlog suggestion for a human to triage; it is never started automatically.',
      '* Do not edit the dashboard task store directly.',
    ].join('\n'));
  }
  return neutralizePlanSyntax(sections.join('\n\n')) + '\n';
}

function clip(value: unknown, max: number): string { return typeof value === 'string' ? value.trim().slice(0, max) : ''; }
function parseJsonObject(text: string | null): Record<string, unknown> | null {
  if (text === null) return null;
  try { const data = JSON.parse(text); return data && typeof data === 'object' && !Array.isArray(data) ? data : null; } catch { return null; }
}
/** Parses the agent-written result file. Anything unreadable or malformed is reported as `missing` so a human reviews it. */
export function parseAttemptResult(text: string | null): { outcome: ResultOutcome; summary?: string; followUps: FollowUp[] } {
  if (text === null) return { outcome: 'missing', summary: 'The run finished without writing a result file.', followUps: [] };
  const record = parseJsonObject(text);
  if (!record) return { outcome: 'missing', summary: 'The result file is not a valid JSON object.', followUps: [] };
  const outcome = record['outcome'];
  if (outcome !== 'done' && outcome !== 'blocked' && outcome !== 'needs_human') return { outcome: 'missing', summary: `The result file has an unknown outcome: ${String(outcome)}`, followUps: [] };
  const followUps = (Array.isArray(record['followUps']) ? record['followUps'] : [])
    .map((item: unknown) => item && typeof item === 'object' ? { title: clip((item as Record<string, unknown>)['title'], 200), description: clip((item as Record<string, unknown>)['description'], 4000) } : null)
    .filter((item): item is FollowUp => !!item && !!item.title)
    .slice(0, MAX_FOLLOW_UPS);
  return { outcome, summary: clip(record['summary'], 2000) || undefined, followUps };
}

function routableIds(installed: InstalledWorkflows): string[] { return installed.map((w) => w.id).filter((id) => id !== TRIAGE_WORKFLOW && id !== AUTO_WORKFLOW); }

/** Picks the installed workflow a triage recommendation names first. Mentions of losing alternatives come later in the prose. */
export function recommendedWorkflowFromText(text: string, installedIds: readonly string[]): string | null {
  let best: { id: string; index: number } | null = null;
  for (const id of installedIds) {
    const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = new RegExp(`(^|[^A-Za-z0-9_-])${escaped}(?![A-Za-z0-9_-])`).exec(text);
    if (!match) continue;
    const index = match.index + match[1].length;
    if (!best || index < best.index || (index === best.index && id.length > best.id.length)) best = { id, index };
  }
  return best?.id ?? null;
}

/** Resolves a routing attempt's recommendation. The per-attempt result file is authoritative; the
 * triage artifact is a fallback only when exactly one was written during this attempt, so parallel
 * routing passes can never receive each other's answers. */
async function recommendedWorkflowFor(attempt: TaskAttempt, roots: DashboardRoots): Promise<string | null> {
  const installed = routableIds(await listWorkflows(options(roots)).catch(() => [] as InstalledWorkflows));
  const result = parseJsonObject(attempt.resultPath ? await fs.readFile(attempt.resultPath, 'utf8').catch(() => null) : null);
  const declared = typeof result?.['recommendedWorkflow'] === 'string' ? result['recommendedWorkflow'].trim() : '';
  if (declared) return installed.includes(declared) ? declared : null;
  const artifacts = join(roots.workspaceRoot, 'artifacts');
  const entries = await fs.readdir(artifacts, { recursive: true }).catch(() => [] as string[]);
  const since = Date.parse(attempt.startedAt);
  const fresh: string[] = [];
  for (const entry of entries.filter((e) => e.endsWith('triage-recommendation.md'))) {
    const stat = await fs.stat(join(artifacts, entry)).catch(() => null);
    if (stat && stat.mtimeMs >= since) fresh.push(entry);
  }
  if (fresh.length !== 1) return null;
  return recommendedWorkflowFromText(await fs.readFile(join(artifacts, fresh[0]), 'utf8').catch(() => ''), installed);
}

/** Maps Ralph run states onto attempt statuses. Unknown states are still running. */
export function attemptStatusForRunState(state: string): AttemptStatus {
  const s = state.toLowerCase();
  if (/succeeded|completed|success/.test(s)) return 'completed';
  if (/cancel/.test(s)) return 'cancelled';
  if (/fail|error|abort|interrupt/.test(s)) return 'failed';
  if (/blocked/.test(s)) return 'blocked';
  return 'running';
}

/** Applies a finished attempt to its task and returns the follow-up tasks to add. Pure; callers persist. */
export function concludeTaskAttempt(task: Task, attempt: TaskAttempt, poll: AttemptPoll, reviewStatus: string, now = new Date().toISOString()): Task[] {
  Object.assign(attempt, { status: poll.status, endedAt: now, ...(poll.runId ? { runId: poll.runId } : {}), ...(poll.error ? { error: poll.error } : {}), ...(poll.outcome ? { outcome: poll.outcome } : {}), ...(poll.summary ? { summary: poll.summary } : {}) });
  task.updatedAt = now;
  if (poll.status === 'completed' && attempt.autoRoute) {
    task.failureCount = 0;
    if (poll.recommendedWorkflow) {
      // Routing only picks the delivery workflow; the task returns to the status it was pulled from so a worker runs it next.
      task.workflowId = poll.recommendedWorkflow;
      task.autoRecommendation = poll.recommendedWorkflow;
      task.status = attempt.sourceStatus ?? DEFAULT_WORKER_STATUS;
    } else {
      // Never fall back to re-running triage: a worker would route the same task forever.
      task.workflowId = AUTO_WORKFLOW;
      task.autoRecommendation = 'Triage finished without naming an installed workflow. Read its recommendation and assign one.';
      task.status = 'blocked';
    }
    return [];
  }
  if (poll.status === 'completed') {
    task.failureCount = 0;
    task.status = poll.outcome === 'blocked' ? 'blocked' : reviewStatus;
  } else if (poll.status === 'failed') {
    task.failureCount = (task.failureCount ?? 0) + 1;
    task.status = task.failureCount >= MAX_TASK_FAILURES ? 'blocked' : attempt.sourceStatus ?? DEFAULT_WORKER_STATUS;
    if (task.failureCount >= MAX_TASK_FAILURES) attempt.summary = `Stopped retrying after ${task.failureCount} failed runs.`;
  } else {
    // Cancelled by someone, or the run is waiting on a human: never retry automatically.
    task.status = 'blocked';
  }
  return followUpTasks(poll.followUps ?? [], { workflowId: task.workflowId, scope: task.scope, targetMode: task.targetMode, targetWorkspaceRoot: task.targetWorkspaceRoot, projectPath: task.projectPath, parentTaskId: task.id }, now);
}

/** Records a task that could not start because its workflow is not installed. Retrying cannot fix that, so it blocks immediately. */
export function recordUnstartableTask(task: Task, message: string, now = new Date().toISOString()): void {
  task.attempts.push({ id: `attempt-${randomUUID()}`, startedAt: now, endedAt: now, status: 'failed', error: message, logPath: '' });
  task.status = 'blocked';
  task.updatedAt = now;
}

function followUpTasks(items: FollowUp[], base: Pick<Task, 'workflowId' | 'scope'> & Partial<Pick<Task, 'targetMode' | 'targetWorkspaceRoot' | 'projectPath' | 'parentTaskId'>>, now: string): Task[] {
  const defined = Object.fromEntries(Object.entries(base).filter(([, v]) => v !== undefined)) as typeof base;
  return items.map((item) => ({ ...defined, id: `task-${randomUUID()}`, title: item.title, description: item.description, acceptanceCriteria: '', status: 'backlog', createdAt: now, updatedAt: now, attempts: [] }));
}

/** Schedule fields a client may change. Everything else (ids, bookkeeping) is server-owned. `worker: null` converts a worker back into a workflow schedule. */
export function pickSchedulePatch(body: Record<string, unknown>): SchedulePatch {
  const patch: SchedulePatch = {};
  for (const key of ['name', 'workflowId', 'cron', 'timezone', 'brief', 'targetWorkspaceRoot'] as const) if (typeof body[key] === 'string') patch[key] = body[key] as string;
  if (typeof body['enabled'] === 'boolean') patch.enabled = body['enabled'];
  if (body['worker'] === null) patch.worker = null;
  else if (body['worker'] && typeof body['worker'] === 'object') patch.worker = normalizeWorker(body['worker']);
  return patch;
}

/** How many tasks a worker may start now, given how many of its tasks are still running. */
export function workerSlots(worker: TaskWorker, running: number): number {
  return worker.mode === 'one' ? (running > 0 ? 0 : 1) : Math.max(0, worker.maxConcurrent - running);
}

// ---------------------------------------------------------------------------
// Launching and polling
// ---------------------------------------------------------------------------

export class WorkflowUnavailableError extends Error {}

function optionalRuntimeModelField(value: unknown): string | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed || undefined;
}

export async function launchAttempt(
  roots: DashboardRoots,
  request: { workflowId: string; heading: string; instructions?: string; task?: Task; scheduleId?: string; runtime?: string; model?: string },
  installed?: InstalledWorkflows,
): Promise<TaskAttempt> {
  const autoRoute = request.workflowId === AUTO_WORKFLOW;
  const workflowId = autoRoute ? TRIAGE_WORKFLOW : request.workflowId;
  const available = installed ?? await listWorkflows(options(roots));
  if (!available.some((workflow) => workflow.id === workflowId)) throw new WorkflowUnavailableError(autoRoute ? 'Auto routing needs the triage workflow, which is not installed' : `Workflow "${workflowId}" is unavailable`);
  const now = new Date().toISOString();
  const id = `attempt-${randomUUID()}`;
  const runDir = join(roots.workspaceRoot, 'artifacts', 'dashboard-runs');
  const suppliedPlanPath = request.task?.leafPlan?.path ? resolve(roots.projectRoot, request.task.leafPlan.path) : undefined;
  if (suppliedPlanPath && (!suppliedPlanPath.startsWith(`${resolve(roots.workspaceRoot, 'plans')}/`) || !existsSync(suppliedPlanPath))) throw new Error('The attached leaf plan is unavailable in this workspace');
  const attempt: TaskAttempt = { id, startedAt: now, status: 'launching', executionKind: 'workflow', workflowId, ...(suppliedPlanPath ? { planPath: request.task!.leafPlan!.path } : {}), ...(autoRoute ? { autoRoute: true } : {}), projectRoot: roots.projectRoot, workspaceRoot: roots.workspaceRoot, logPath: join(runDir, `${id}.log`), briefPath: join(runDir, `${id}.brief.md`), resultPath: join(runDir, `${id}.result.json`), ...(request.scheduleId ? { scheduleId: request.scheduleId } : {}) };
  await fs.mkdir(runDir, { recursive: true });
  if (request.task) {
    attempt.snapshotPath = join(roots.workspaceRoot, 'artifacts', 'dashboard-tasks', `${request.task.id}-${Date.now()}.json`);
    await fs.mkdir(dirname(attempt.snapshotPath), { recursive: true });
    await fs.writeFile(attempt.snapshotPath, JSON.stringify({ task: request.task, attemptId: id, launchedAt: now }, null, 2));
  }
  const routeTo = autoRoute ? available.filter((w) => routableIds([w]).length).map((w) => ({ id: w.id, overview: w.overview })) : undefined;
  await fs.writeFile(attempt.briefPath!, renderBrief({ heading: request.heading, instructions: request.instructions, task: request.task, snapshotPath: attempt.snapshotPath, resultPath: attempt.resultPath!, routeTo }));
  const runtime = request.runtime ?? request.task?.runtime;
  const model = request.model ?? request.task?.model;
  const handle = startWorkflowDetached(
    {
      id: workflowId,
      taskFile: suppliedPlanPath ?? attempt.briefPath,
      ...(runtime ? { runtime } : {}),
      ...(runtime && model ? { model } : {}),
    },
    attempt.logPath,
    options(roots),
  );
  attempt.pid = handle.pid;
  return attempt;
}

export async function launchLeafPlanAttempt(roots: DashboardRoots, task: Task): Promise<TaskAttempt> {
  if (!task.leafPlan?.path) throw new Error('This task does not have an attached leaf plan');
  const planPath = resolve(roots.projectRoot, task.leafPlan.path);
  const allowed = resolve(roots.workspaceRoot, 'plans');
  if (!planPath.startsWith(`${allowed}/`) || !existsSync(planPath)) throw new Error('The attached leaf plan is unavailable in this workspace');
  const id = `attempt-${randomUUID()}`;
  const now = new Date().toISOString();
  const runDir = join(roots.workspaceRoot, 'artifacts', 'dashboard-runs');
  await fs.mkdir(runDir, { recursive: true });
  const attempt: TaskAttempt = { id, startedAt: now, status: 'launching', executionKind: 'leaf-plan', planPath: task.leafPlan.path, projectRoot: roots.projectRoot, workspaceRoot: roots.workspaceRoot, logPath: join(runDir, `${id}.log`) };
  attempt.pid = runPlanDetached(planPath, attempt.logPath, options(roots)).pid;
  return attempt;
}

function processAlive(pid: number): boolean { try { process.kill(pid, 0); return true; } catch (error) { return (error as NodeJS.ErrnoException).code === 'EPERM'; } }
async function logTail(path: string, lines = 6): Promise<string> { const text = await fs.readFile(path, 'utf8').catch(() => ''); return text.trimEnd().split('\n').slice(-lines).join('\n'); }
function attemptRoots(attempt: TaskAttempt, fallback: DashboardRoots): DashboardRoots { return attempt.projectRoot && attempt.workspaceRoot ? { projectRoot: attempt.projectRoot, workspaceRoot: attempt.workspaceRoot } : fallback; }

function isWorkflowRunLookupMiss(error: unknown): boolean {
  if (!(error instanceof RalphCliError)) {
    return false;
  }
  return /not found/i.test(error.stderr) || /not found/i.test(error.message);
}

/** Returns the attempt's new state, or null when nothing changed. Reads the result file once the run completes. */
export async function pollAttempt(attempt: TaskAttempt, fallback: DashboardRoots): Promise<AttemptPoll | null> {
  if (attempt.executionKind === 'leaf-plan') {
    if (attempt.pid && processAlive(attempt.pid)) return attempt.status !== 'running' ? { status: 'running' } : null;
    const roots = attemptRoots(attempt, fallback);
    const planPath = attempt.planPath ? resolve(roots.projectRoot, attempt.planPath) : '';
    const content = planPath ? await fs.readFile(planPath, 'utf8').catch(() => null) : null;
    if (content !== null && !hasOpenTodos(content)) return { status: 'completed', outcome: 'done', summary: 'Leaf plan completed.' };
    return { status: 'failed', error: (await logTail(attempt.logPath)) || 'Leaf plan stopped before all TODOs completed.' };
  }
  let runId = attempt.runId;
  let discovered = false;
  if (!runId) {
    const text = await fs.readFile(attempt.logPath, 'utf8').catch(() => '');
    const match = /^Run: (\S+)/m.exec(text);
    if (match) { runId = match[1]; discovered = true; }
  }
  if (!runId) {
    const dead = attempt.pid ? !processAlive(attempt.pid) : Date.now() - Date.parse(attempt.startedAt) > LAUNCH_STALE_MS;
    return dead ? { status: 'failed', error: (await logTail(attempt.logPath)) || 'ralph workflow start exited before a run was created' } : null;
  }
  let status: AttemptStatus = 'running';
  try {
    const run = (await runStatus(runId, options(attemptRoots(attempt, fallback)))) as Record<string, unknown>;
    status = attemptStatusForRunState(String(run['state'] ?? run['status'] ?? ''));
  } catch (error: unknown) {
    if (runId && isWorkflowRunLookupMiss(error)) {
      const bound = attempt.runId === runId;
      const dead = attempt.pid ? !processAlive(attempt.pid) : Date.now() - Date.parse(attempt.startedAt) > LAUNCH_STALE_MS;
      if (bound || dead) {
        return {
          runId,
          status: 'failed',
          error: `Workflow run ${runId} was not found; clearing stale attempt.`,
        };
      }
    }
    /* run may not be materialized yet */
  }
  if (status === 'running') return discovered || attempt.status !== 'running' ? { runId, status } : null;
  if (status !== 'completed') return { runId, status, ...(status === 'blocked' ? { summary: 'The workflow run is blocked and needs attention from the run page.' } : {}) };
  if (attempt.autoRoute) return { runId, status, recommendedWorkflow: await recommendedWorkflowFor(attempt, attemptRoots(attempt, fallback)) };
  if (attempt.planPath) return { runId, status, outcome: 'done', summary: 'Workflow completed with the attached leaf plan.' };
  const resultText = attempt.resultPath ? await fs.readFile(attempt.resultPath, 'utf8').catch(() => null) : null;
  return { runId, status, ...parseAttemptResult(resultText) };
}

async function reviewStatusFor(workspaceRoot: string | undefined): Promise<string> {
  if (!workspaceRoot) return 'review';
  const statuses = (await readStoreFile(projectStoreFile(workspaceRoot))).taskStatuses;
  return !statuses?.length || statuses.includes('review') ? 'review' : 'blocked';
}

/** Records a finished scheduled run against its schedule, pausing it after repeated failures. */
export function recordScheduleResult(schedule: Schedule, failed: boolean): void {
  if (!failed) { schedule.consecutiveFailures = 0; return; }
  schedule.consecutiveFailures = (schedule.consecutiveFailures ?? 0) + 1;
  if (schedule.consecutiveFailures >= MAX_CONSECUTIVE_SCHEDULE_FAILURES && schedule.enabled) {
    schedule.enabled = false;
    schedule.lastError = `Paused after ${schedule.consecutiveFailures} consecutive failed runs. Fix the cause, then enable it again.`;
  }
}

type ScheduleEffect = { scheduleId: string; workspaceRoot?: string; failed: boolean };

async function applyScheduleEffect(effect: ScheduleEffect): Promise<void> {
  const paths = [...(effect.workspaceRoot ? [projectStoreFile(effect.workspaceRoot)] : []), globalStoreFile()];
  for (const path of paths) {
    if (!(await readStoreFile(path)).schedules.some((s) => s.id === effect.scheduleId)) continue;
    await updateStoreFile(path, (store) => { const schedule = store.schedules.find((s) => s.id === effect.scheduleId); if (schedule) recordScheduleResult(schedule, effect.failed); });
    return;
  }
}

/** Polls every active attempt in one store file outside the lock (CLI calls are slow), then applies all changes under it. */
async function refreshStoreFile(path: string, fallback: DashboardRoots): Promise<void> {
  const snapshot = await readStoreFile(path);
  const taskPolls: Array<{ taskId: string; attemptId: string; poll: AttemptPoll; reviewStatus: string }> = [];
  const schedulePolls: Array<{ scheduleId: string; poll: AttemptPoll }> = [];
  for (const task of snapshot.tasks) for (const attempt of task.attempts.filter((a) => ACTIVE.has(a.status))) {
    const poll = await pollAttempt(attempt, fallback);
    if (poll) taskPolls.push({ taskId: task.id, attemptId: attempt.id, poll, reviewStatus: await reviewStatusFor(attempt.workspaceRoot ?? fallback.workspaceRoot) });
  }
  for (const schedule of snapshot.schedules) if (schedule.activeAttempt && ACTIVE.has(schedule.activeAttempt.status)) {
    const poll = await pollAttempt(schedule.activeAttempt, fallback);
    if (poll) schedulePolls.push({ scheduleId: schedule.id, poll });
  }
  if (!taskPolls.length && !schedulePolls.length) return;
  const effects: ScheduleEffect[] = [];
  await updateStoreFile(path, (store) => {
    const now = new Date().toISOString();
    for (const { taskId, attemptId, poll, reviewStatus } of taskPolls) {
      const task = store.tasks.find((t) => t.id === taskId);
      const attempt = task?.attempts.find((a) => a.id === attemptId);
      if (!task || !attempt || !ACTIVE.has(attempt.status)) continue;
      if (ACTIVE.has(poll.status)) { Object.assign(attempt, { status: poll.status, ...(poll.runId ? { runId: poll.runId } : {}) }); continue; }
      store.tasks.push(...concludeTaskAttempt(task, attempt, poll, reviewStatus, now));
      if (attempt.scheduleId) effects.push({ scheduleId: attempt.scheduleId, workspaceRoot: attempt.workspaceRoot, failed: poll.status === 'failed' });
    }
    for (const { scheduleId, poll } of schedulePolls) {
      const schedule = store.schedules.find((s) => s.id === scheduleId);
      const attempt = schedule?.activeAttempt;
      if (!schedule || !attempt || !ACTIVE.has(attempt.status)) continue;
      Object.assign(attempt, { status: poll.status, ...(poll.runId ? { runId: poll.runId } : {}), ...(poll.error ? { error: poll.error } : {}), ...(poll.outcome ? { outcome: poll.outcome } : {}), ...(poll.summary ? { summary: poll.summary } : {}) });
      if (ACTIVE.has(poll.status)) continue;
      attempt.endedAt = now;
      recordScheduleResult(schedule, poll.status === 'failed');
      if (poll.followUps?.length) {
        store.tasks.push(...followUpTasks(poll.followUps, { workflowId: schedule.workflowId, scope: schedule.scope, targetMode: 'registered', ...(schedule.scope === 'global' ? { targetWorkspaceRoot: attempt.workspaceRoot } : {}) }, now));
      }
    }
  });
  for (const effect of effects) await applyScheduleEffect(effect);
}

async function refreshAttempts(roots: DashboardRoots): Promise<void> {
  await refreshStoreFile(storePath(roots, 'project'), roots);
  await refreshStoreFile(storePath(roots, 'global'), roots);
}

// ---------------------------------------------------------------------------
// Scheduling
// ---------------------------------------------------------------------------

export type ScheduleRunResult = { launched: boolean; reason?: string; schedule?: Schedule };

/** Tasks in `status` that a worker in `roots` may pull, oldest first. */
async function tasksInStatus(roots: DashboardRoots, status: string): Promise<Array<{ task: Task; scope: Scope }>> {
  const out: Array<{ task: Task; scope: Scope }> = [];
  for (const taskScope of ['project', 'global'] as const) {
    for (const task of (await readStore(roots, taskScope)).tasks) {
      if (task.status !== status) continue;
      if (taskScope === 'global' && !sameRoot(task.targetWorkspaceRoot, roots.workspaceRoot) && !(!task.targetWorkspaceRoot && task.targetMode !== 'registered')) continue;
      out.push({ task, scope: taskScope });
    }
  }
  return out.sort((a, b) => a.task.createdAt.localeCompare(b.task.createdAt));
}

async function runTaskWorker(roots: DashboardRoots, scheduleScope: Scope, current: Schedule): Promise<ScheduleRunResult> {
  const worker = current.worker!;
  const tasks = await allTasks(roots);
  const running = (current.activeTaskIds ?? []).filter((id) => tasks.some((task) => task.id === id && task.status === 'in_progress'));
  const slots = workerSlots(worker, running.length);
  /** Persists bookkeeping; finished task ids drop out of activeTaskIds on every pass. */
  const finish = (mutate: (s: Schedule) => void) => updateStore(roots, scheduleScope, (store) => { const s = store.schedules.find((x) => x.id === current.id); if (s) { s.activeTaskIds = [...running]; s.nextRunAt = previewCron(s.cron, s.timezone, 1)[0]; mutate(s); } return s; });
  if (!slots) {
    const schedule = await finish(() => undefined);
    return { launched: false, reason: worker.mode === 'one' ? 'the current task has not finished' : `already running ${running.length} of ${worker.maxConcurrent} tasks`, schedule };
  }
  const statusError = workerStatusError(worker.status);
  if (statusError) {
    const schedule = await finish((s) => { s.lastError = statusError; });
    return { launched: false, reason: statusError, schedule };
  }
  const candidates = await tasksInStatus(roots, worker.status);
  if (!candidates.length) {
    const schedule = await finish(() => undefined);
    return { launched: false, reason: `no tasks in ${worker.status}`, schedule };
  }

  let installed: InstalledWorkflows;
  try { installed = await listWorkflows(options(roots)); } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const schedule = await finish((s) => { s.lastRunAt = new Date().toISOString(); recordScheduleResult(s, true); if (s.enabled) s.lastError = message; });
    return { launched: false, reason: message, schedule };
  }

  const launched: string[] = [];
  const skipped: string[] = [];
  let systemError: string | undefined;
  for (const { task, scope: taskScope } of candidates) {
    if (launched.length >= slots) break;
    try {
      const attempt = await launchAttempt(roots, { workflowId: effectiveWorkflow(task), heading: `Task worker "${current.name}": task ${task.id}`, instructions: current.brief, task, scheduleId: current.id }, installed);
      attempt.sourceStatus = task.status;
      await updateStore(roots, taskScope, (store) => { const t = store.tasks.find((x) => x.id === task.id); if (t) { t.status = 'in_progress'; t.updatedAt = attempt.startedAt; t.attempts.push(attempt); } });
      launched.push(task.id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (error instanceof WorkflowUnavailableError) {
        // Task-specific and permanent: park it and keep draining the queue.
        await updateStore(roots, taskScope, (store) => { const t = store.tasks.find((x) => x.id === task.id); if (t) recordUnstartableTask(t, message); });
        skipped.push(`${task.title}: ${message}`);
        continue;
      }
      // Anything else (spawn or filesystem failure) would hit every task alike; stop without penalizing tasks.
      systemError = message;
      break;
    }
  }

  const schedule = await finish((s) => {
    s.lastRunAt = new Date().toISOString();
    s.activeTaskIds = [...running, ...launched];
    if (systemError && !launched.length) { recordScheduleResult(s, true); if (s.enabled) s.lastError = systemError; }
    else s.lastError = [systemError, ...skipped.map((note) => `Blocked ${note}`)].filter(Boolean).join('\n') || undefined;
  });
  return launched.length ? { launched: true, schedule } : { launched: false, reason: systemError ?? (skipped.length ? `no startable tasks (${skipped.length} blocked)` : `no tasks in ${worker.status}`), schedule };
}

/** Runs one schedule in `roots`. Scheduled fires skip paused schedules; manual runs do not. Neither overlaps unfinished work beyond the schedule's limit. */
export async function runSchedule(roots: DashboardRoots, scheduleScope: Scope, scheduleId: string, manual: boolean): Promise<ScheduleRunResult> {
  const current = (await readStore(roots, scheduleScope)).schedules.find((s) => s.id === scheduleId);
  if (!current) return { launched: false, reason: 'schedule not found' };
  if (!manual && !current.enabled) return { launched: false, reason: 'schedule is paused', schedule: current };
  if (current.worker) return runTaskWorker(roots, scheduleScope, current);
  if (current.activeAttempt && ACTIVE.has(current.activeAttempt.status)) return { launched: false, reason: 'the previous run has not finished', schedule: current };

  let attempt: TaskAttempt | undefined;
  let launchError: string | undefined;
  try {
    attempt = await launchAttempt(roots, { workflowId: current.workflowId, heading: `Scheduled run "${current.name}"`, instructions: current.brief, scheduleId: current.id });
  } catch (error) {
    launchError = error instanceof Error ? error.message : String(error);
  }
  const schedule = await updateStore(roots, scheduleScope, (store) => {
    const s = store.schedules.find((x) => x.id === scheduleId);
    if (!s) return undefined;
    s.lastRunAt = new Date().toISOString();
    s.nextRunAt = previewCron(s.cron, s.timezone, 1)[0];
    if (attempt) { s.lastError = undefined; s.activeAttempt = attempt; }
    else { recordScheduleResult(s, true); if (s.enabled) s.lastError = launchError; }
    return s;
  });
  return attempt ? { launched: true, schedule } : { launched: false, reason: launchError, schedule };
}

/** Every workspace the scheduler serves: the dashboard's own project plus all registered ones. */
async function schedulerWorkspaces(): Promise<DashboardRoots[]> {
  const out: DashboardRoots[] = [findDashboardRoots()];
  for (const entry of await getMergedWorkspaceAllowlist().catch(() => [])) {
    if (!out.some((roots) => sameRoot(roots.workspaceRoot, entry.workspaceRoot)) && existsSync(entry.workspaceRoot)) out.push({ projectRoot: entry.projectRoot, workspaceRoot: entry.workspaceRoot });
  }
  return out;
}

const firedMinute = new Map<string, number>();
let tickInFlight = false;

/** One scheduler pass. Overlapping calls are dropped, so a slow pass can never double-launch. */
export async function schedulerTick(now = new Date()): Promise<void> {
  if (tickInFlight) return;
  tickInFlight = true;
  try {
    const workspaces = await schedulerWorkspaces();
    for (const roots of workspaces) await refreshStoreFile(storePath(roots, 'project'), roots);
    await refreshStoreFile(globalStoreFile(), workspaces[0]);
    const minute = Math.floor(now.getTime() / 60_000);
    const due = (s: Schedule) => s.enabled && firedMinute.get(s.id) !== minute && (!s.lastRunAt || Math.floor(Date.parse(s.lastRunAt) / 60_000) !== minute) && cronDueNow(s.cron, s.timezone, now);
    for (const roots of workspaces) {
      for (const schedule of (await readStore(roots, 'project')).schedules.filter(due)) { firedMinute.set(schedule.id, minute); await runSchedule(roots, 'project', schedule.id, false); }
    }
    for (const schedule of (await readStoreFile(globalStoreFile())).schedules.filter(due)) {
      firedMinute.set(schedule.id, minute);
      const target = workspaces.find((roots) => sameRoot(roots.workspaceRoot, schedule.targetWorkspaceRoot));
      if (target) { await runSchedule(target, 'global', schedule.id, false); continue; }
      await updateStoreFile(globalStoreFile(), (store) => { const s = store.schedules.find((x) => x.id === schedule.id); if (s) { s.lastError = 'Global schedules need a registered target project. Edit the schedule and choose one.'; s.nextRunAt = previewCron(s.cron, s.timezone, 1)[0]; } });
    }
  } catch (error) {
    console.error('[dashboard-scheduler] tick failed:', error instanceof Error ? error.message : error);
  } finally {
    tickInFlight = false;
  }
}

export function startDashboardScheduler(app: Express): void { const key = 'dashboard-scheduler'; if (schedulerTimers.has(key)) return; const timer = setInterval(() => { void schedulerTick(); }, 30_000); timer.unref(); schedulerTimers.set(key, timer); void app; }

async function findScope(roots: DashboardRoots, kind: 'tasks' | 'schedules', id: string): Promise<Scope | undefined> {
  for (const recordScope of ['project', 'global'] as const) if ((await readStore(roots, recordScope))[kind].some((record) => record.id === id)) return recordScope;
  return undefined;
}

export type TaskStoreLocation = { scope: Scope; storeRoots: DashboardRoots };

/** Project-scoped tasks live in the dashboard home store; launch uses target workspace roots for execution. */
export async function locateTaskStore(
  id: string,
  requestRoots: DashboardRoots,
  homeRoots: DashboardRoots = findDashboardRoots(),
): Promise<TaskStoreLocation | undefined> {
  const rootsToSearch: DashboardRoots[] = [requestRoots];
  if (!sameRoot(homeRoots.workspaceRoot, requestRoots.workspaceRoot)) {
    rootsToSearch.push(homeRoots);
  }
  for (const storeRoots of rootsToSearch) {
    for (const scope of ['project', 'global'] as const) {
      if ((await readStore(storeRoots, scope)).tasks.some((task) => task.id === id)) {
        return { scope, storeRoots };
      }
    }
  }
  return undefined;
}

async function locateTask(id: string, requestRoots: DashboardRoots): Promise<TaskStoreLocation | undefined> {
  return locateTaskStore(id, requestRoots, findDashboardRoots());
}

/** A workflow schedule needs a real workflow; Auto only makes sense per task, which is what the task worker is for. */
function scheduleShapeError(schedule: Pick<Schedule, 'worker' | 'workflowId'>): string | null {
  if (schedule.worker) return workerStatusError(schedule.worker.status);
  if (!schedule.workflowId?.trim()) return 'choose a workflow, or the built-in task worker';
  if (schedule.workflowId === AUTO_WORKFLOW) return 'Auto routes individual tasks; use the built-in task worker to run it on a schedule';
  return null;
}

export function registerTaskScheduleApi(app: Express): void {
  app.get('/api/runs', middleware, async (req, res) => {
    const roots = context(req); await refreshAttempts(roots);
    const workflows = await listWorkflowRuns({}, options(roots)).catch(() => []);
    const leafRuns = (await allTasks(roots)).flatMap((task) => task.attempts.filter((attempt) => attempt.executionKind === 'leaf-plan').map((attempt) => ({ runId: attempt.id, workflowId: '', mode: 'leaf', entryKind: 'leaf-plan', executionKind: 'leaf-plan', state: attempt.status === 'completed' ? 'succeeded' : attempt.status, createdAt: attempt.startedAt, task: task.title, sourceKind: task.leafPlan?.title || 'leaf plan', graphRunLink: null })));
    res.json([...(workflows as readonly Record<string, unknown>[]).map((run) => ({ ...run, executionKind: 'workflow' })), ...leafRuns]);
  });
  app.get('/api/dashboard-templates', (_req, res) =>
    res.json(
      TEMPLATES.map(([id, category, purpose, outputs]) => ({
        id,
        category,
        purpose,
        outputs,
        stageCount: 1,
        installable: true,
        safety:
          category === 'Trade analysis'
            ? 'Analysis only; no broker or trade execution.'
            : category === 'Assistants'
              ? 'Requires configured connector.'
              : 'Project workflow.',
      })),
    ),
  );
  app.post('/api/dashboard-templates/:id/install', middleware, writeGuard, async (req, res) => {
    const found = TEMPLATES.find(([id]) => id === req.params['id']); if (!found) return jsonError(res, 404, 'template not found');
    const roots = context(req); const recordScope = (req.body as Record<string, unknown>)['scope'] === 'global' ? 'global' : 'project';
    const dir = recordScope === 'global' ? join(process.env['RALPH_HOME']?.trim() || join(homedir(), '.ralph'), 'workflows') : join(roots.workspaceRoot, 'workflows');
    const target = join(dir, `${found[0]}.workflow.md`); if (existsSync(target)) return res.status(200).json({ id: found[0], scope: recordScope, created: false });
    await fs.mkdir(dir, { recursive: true }); const temp = `${target}.${randomUUID()}.tmp`; const content = templateContent(found[0], found[2]);
    try { await fs.writeFile(temp, content); await inspectWorkflow({ file: temp }, 'json', options(roots)); await fs.rename(temp, target); res.status(201).json({ id: found[0], scope: recordScope, created: true }); } catch (error) { await fs.unlink(temp).catch(() => undefined); jsonError(res, 422, error instanceof Error ? error.message : 'template validation failed'); }
  });
  app.get('/api/tasks', middleware, async (req, res) => { const roots = context(req); await refreshAttempts(roots); res.json(await allTasks(roots)); });
  app.get('/api/task-statuses', middleware, async (req, res) => { const roots = context(req); const store = await readStore(roots, 'project'); res.json(store.taskStatuses?.length ? store.taskStatuses : DEFAULT_TASK_STATUSES); });
  app.put('/api/task-statuses', middleware, writeGuard, async (req, res) => { const roots = context(req); const values = (req.body as Record<string, unknown>)['statuses']; if (!Array.isArray(values)) return jsonError(res, 400, 'statuses must be an array'); const statuses = [...new Set(values.filter((x): x is string => typeof x === 'string').map((x) => x.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '')).filter(Boolean))]; if (!statuses.length) return jsonError(res, 400, 'at least one status is required'); const conflict = await updateStore(roots, 'project', (store) => { const used = new Set(store.tasks.map((task) => task.status)); if ([...used].some((status) => !statuses.includes(status))) return true; store.taskStatuses = statuses; return false; }); if (conflict) return jsonError(res, 409, 'move tasks out of a status before removing it'); res.json(statuses); });
  app.post('/api/tasks', middleware, writeGuard, async (req, res) => { const roots = context(req); const body = req.body as Record<string, unknown>; const recordScope = scope(body); const title = typeof body['title'] === 'string' ? body['title'].trim() : ''; if (!title) return jsonError(res, 400, 'title is required'); const target = typeof body['targetWorkspaceRoot'] === 'string' ? body['targetWorkspaceRoot'].trim() : ''; const targetMode = body['targetMode'] === 'new-project' ? 'new-project' : body['targetMode'] === 'global' ? 'global' : 'registered'; if (recordScope === 'global' && targetMode === 'registered' && !target) return jsonError(res, 400, 'global tasks require a target project, or choose New project / Global setup'); if (recordScope === 'global' && targetMode === 'registered' && !(await isRegisteredWorkspace(target))) return jsonError(res, 400, 'global task target project is not registered'); const now = new Date().toISOString(); const runtime = optionalRuntimeModelField(body['runtime']); const model = optionalRuntimeModelField(body['model']); const task: Task = { id: `task-${randomUUID()}`, title, description: typeof body['description'] === 'string' ? body['description'] : '', acceptanceCriteria: typeof body['acceptanceCriteria'] === 'string' ? body['acceptanceCriteria'] : '', workflowId: typeof body['workflowId'] === 'string' && body['workflowId'].trim() ? body['workflowId'].trim() : AUTO_WORKFLOW, scope: recordScope, targetMode, ...(target ? { targetWorkspaceRoot: target } : {}), ...(typeof body['projectPath'] === 'string' ? { projectPath: body['projectPath'] } : {}), ...(runtime ? { runtime } : {}), ...(runtime && model ? { model } : {}), status: (body['status'] as TaskStatus) || 'backlog', createdAt: now, updatedAt: now, attempts: [] }; await updateStore(roots, recordScope, (store) => { store.tasks.push(task); }); res.status(201).json(task); });
  app.patch('/api/tasks/:id', middleware, writeGuard, async (req, res) => {
    const roots = context(req); const body = req.body as Record<string, unknown>; const id = String(req.params['id']);
    const located = await locateTask(id, roots); if (!located) return jsonError(res, 404, 'task not found');
    const result = await updateStore(located.storeRoots, located.scope, (store): { task: Task } | { status: number; error: string } => {
      const task = store.tasks.find((x) => x.id === id); if (!task) return { status: 404, error: 'task not found' };
      const draft: Task = { ...task };
      for (const key of ['title','description','acceptanceCriteria','workflowId','status','targetWorkspaceRoot','targetMode','projectPath'] as const) if (typeof body[key] === 'string') (draft as Record<string, unknown>)[key] = body[key];
      if ('runtime' in body) {
        const runtime = optionalRuntimeModelField(body['runtime']);
        if (runtime) {
          draft.runtime = runtime;
        } else {
          delete draft.runtime;
          delete draft.model;
        }
      }
      if ('model' in body) {
        const model = optionalRuntimeModelField(body['model']);
        if (model) {
          draft.model = model;
        } else {
          delete draft.model;
        }
      }
      if (draft.scope === 'global' && (draft.targetMode ?? 'registered') === 'registered' && !draft.targetWorkspaceRoot) return { status: 400, error: 'global tasks require a target project, or New project / Global setup' };
      // A person moving a task back to ready is a deliberate retry: restore its automatic retry budget.
      if (draft.status === 'ready' && task.status !== 'ready') draft.failureCount = 0;
      draft.updatedAt = new Date().toISOString();
      Object.assign(task, draft); return { task };
    });
    if ('error' in result) return jsonError(res, result.status, result.error);
    res.json(result.task);
  });
  app.get('/api/tasks/:id/leaf-plan', middleware, async (req, res) => {
    const roots = context(req); const id = String(req.params['id']); const located = await locateTask(id, roots);
    if (!located) return jsonError(res, 404, 'task not found');
    const task = (await readStore(located.storeRoots, located.scope)).tasks.find((x) => x.id === id)!;
    if (!task.leafPlan) return jsonError(res, 404, 'leaf plan not found');
    const path = resolve(roots.projectRoot, task.leafPlan.path);
    res.json({ ...task.leafPlan, content: await fs.readFile(path, 'utf8').catch(() => '') });
  });
  app.put('/api/tasks/:id/leaf-plan', middleware, writeGuard, async (req, res) => {
    const roots = context(req); const id = String(req.params['id']); const body = req.body as Record<string, unknown>; const located = await locateTask(id, roots);
    if (!located) return jsonError(res, 404, 'task not found');
    const task = (await readStore(located.storeRoots, located.scope)).tasks.find((x) => x.id === id)!;
    if (task.status === 'in_progress') return jsonError(res, 409, 'leaf plans cannot be edited while the task is running');
    const title = typeof body['title'] === 'string' && body['title'].trim() ? body['title'].trim().slice(0, 200) : task.title;
    const content = typeof body['content'] === 'string' ? body['content'] : classicPlan(title, task);
    if (!hasOpenTodos(content)) return jsonError(res, 400, 'a leaf plan needs at least one open - [ ] TODO');
    const path = managedPlanPath(roots, task.id); await fs.mkdir(dirname(path), { recursive: true });
    const temp = `${path}.${randomUUID()}.tmp`; await fs.writeFile(temp, content, 'utf8'); await fs.rename(temp, path);
    const leafPlan: LeafPlan = { path: relative(roots.projectRoot, path), title, updatedAt: new Date().toISOString() };
    const updated = await updateStore(located.storeRoots, located.scope, (store) => { const current = store.tasks.find((x) => x.id === id); if (current) { current.leafPlan = leafPlan; current.updatedAt = leafPlan.updatedAt; } return current; });
    res.json(updated);
  });
  app.post('/api/tasks/:id/launch-leaf-plan', middleware, writeGuard, async (req, res) => {
    const roots = context(req); const id = String(req.params['id']); const located = await locateTask(id, roots);
    if (!located) return jsonError(res, 404, 'task not found');
    const task = (await readStore(located.storeRoots, located.scope)).tasks.find((x) => x.id === id)!;
    if (task.status !== 'ready' && task.status !== 'backlog') return jsonError(res, 409, 'task must be ready or in backlog before it can be started');
    let attempt: TaskAttempt; try { attempt = await launchLeafPlanAttempt(roots, task); attempt.sourceStatus = task.status; } catch (error) { return jsonError(res, 422, error instanceof Error ? error.message : 'launch failed'); }
    const updated = await updateStore(located.storeRoots, located.scope, (store) => { const current = store.tasks.find((x) => x.id === id); if (current) { current.status = 'in_progress'; current.updatedAt = attempt.startedAt; current.attempts.push(attempt); } return current; });
    res.status(202).json({ task: updated, attempt });
  });
  app.post('/api/leaf-runs/:attemptId/cancel', middleware, writeGuard, async (req, res) => {
    const roots = context(req); const attemptId = String(req.params['attemptId']);
    for (const recordScope of ['project', 'global'] as const) {
      const found = (await readStore(roots, recordScope)).tasks.map((task) => ({ task, attempt: task.attempts.find((a) => a.id === attemptId) })).find((x) => x.attempt?.executionKind === 'leaf-plan');
      if (!found?.attempt) continue;
      if (!ACTIVE.has(found.attempt.status)) return jsonError(res, 409, 'leaf plan run is not active');
      if (found.attempt.pid) { try { process.kill(-found.attempt.pid, 'SIGTERM'); } catch { try { process.kill(found.attempt.pid, 'SIGTERM'); } catch {} } }
      await updateStore(roots, recordScope, (store) => { const task = store.tasks.find((x) => x.id === found.task.id); const attempt = task?.attempts.find((x) => x.id === attemptId); if (task && attempt) { attempt.status = 'cancelled'; attempt.endedAt = new Date().toISOString(); attempt.summary = 'Stopped by operator.'; task.status = 'blocked'; task.updatedAt = attempt.endedAt; } });
      return res.json({ ok: true });
    }
    return jsonError(res, 404, 'leaf plan run not found');
  });
  app.post('/api/tasks/:id/launch', middleware, writeGuard, async (req, res) => {
    const roots = context(req); const id = String(req.params['id']);
    const located = await locateTask(id, roots); if (!located) return jsonError(res, 404, 'task not found');
    const task = (await readStore(located.storeRoots, located.scope)).tasks.find((x) => x.id === id)!;
    if (task.status !== 'ready' && task.status !== 'backlog') return jsonError(res, 409, 'task must be ready or in backlog before it can be started');
    if (task.targetWorkspaceRoot && !sameRoot(task.targetWorkspaceRoot, roots.workspaceRoot)) return jsonError(res, 400, 'task belongs to another target project');
    const launchBody = (req.body ?? {}) as Record<string, unknown>;
    const launchRuntime = optionalRuntimeModelField(launchBody['runtime']);
    const launchModel = optionalRuntimeModelField(launchBody['model']);
    let attempt: TaskAttempt;
    try {
      attempt = await launchAttempt(roots, {
        workflowId: effectiveWorkflow(task),
        heading: `Dashboard task ${task.id}`,
        task,
        ...(launchRuntime ? { runtime: launchRuntime } : {}),
        ...(launchRuntime && launchModel ? { model: launchModel } : {}),
      });
      attempt.sourceStatus = task.status;
    } catch (error) { return jsonError(res, 422, error instanceof Error ? error.message : 'launch failed'); }
    const updated = await updateStore(located.storeRoots, located.scope, (store) => { const t = store.tasks.find((x) => x.id === id); if (t) { t.status = 'in_progress'; t.updatedAt = attempt.startedAt; t.attempts.push(attempt); } return t; });
    res.status(202).json({ task: updated, attempt });
  });
  app.get('/api/schedules', middleware, async (req, res) => {
    const roots = context(req); await refreshAttempts(roots);
    const tasks = await allTasks(roots);
    const data = [...(await readStore(roots, 'project')).schedules, ...(await readStore(roots, 'global')).schedules].map((x) => ({ ...x, activeTaskIds: (x.activeTaskIds ?? []).filter((id) => tasks.some((t) => t.id === id && t.status === 'in_progress')), nextRunAt: previewCron(x.cron, x.timezone, 1)[0], preview: previewCron(x.cron, x.timezone) }));
    res.json(data);
  });
  app.post('/api/schedules/preview', middleware, async (req, res) => { const b = req.body as Record<string, unknown>; if (!validCron(b['cron']) || !validZone(b['timezone'])) return jsonError(res, 400, 'valid five-field cron and IANA timezone are required'); res.json({ times: previewCron(b['cron'], b['timezone']) }); });
  app.post('/api/schedules', middleware, writeGuard, async (req, res) => {
    const roots = context(req); const b = req.body as Record<string, unknown>;
    if (!validCron(b['cron']) || !validZone(b['timezone'])) return jsonError(res, 400, 'valid five-field cron and IANA timezone are required');
    const recordScope = scope(b); const patch = pickSchedulePatch(b);
    const worker = patch.worker ?? undefined;
    const shapeError = scheduleShapeError({ worker, workflowId: patch.workflowId ?? '' }); if (shapeError) return jsonError(res, 400, shapeError);
    if (recordScope === 'global' && !(patch.targetWorkspaceRoot && await isRegisteredWorkspace(patch.targetWorkspaceRoot))) return jsonError(res, 400, 'global schedules require a registered target project');
    const schedule: Schedule = { id: `schedule-${randomUUID()}`, name: patch.name?.trim() || (worker ? 'Task worker' : 'Untitled schedule'), scope: recordScope, workflowId: worker ? '' : patch.workflowId!, cron: b['cron'], timezone: b['timezone'], enabled: patch.enabled !== false, ...(worker ? { worker } : {}), ...(patch.brief !== undefined ? { brief: patch.brief } : {}), ...(recordScope === 'global' ? { targetWorkspaceRoot: patch.targetWorkspaceRoot } : {}), consecutiveFailures: 0, nextRunAt: previewCron(b['cron'], b['timezone'], 1)[0] };
    await updateStore(roots, recordScope, (store) => { store.schedules.push(schedule); });
    res.status(201).json(schedule);
  });
  app.patch('/api/schedules/:id', middleware, writeGuard, async (req, res) => {
    const roots = context(req); const id = String(req.params['id']); const { worker, ...patch } = pickSchedulePatch(req.body as Record<string, unknown>);
    const recordScope = await findScope(roots, 'schedules', id); if (!recordScope) return jsonError(res, 404, 'schedule not found');
    if (recordScope === 'global' && patch.targetWorkspaceRoot !== undefined && !(await isRegisteredWorkspace(patch.targetWorkspaceRoot))) return jsonError(res, 400, 'global schedules require a registered target project');
    const result = await updateStore(roots, recordScope, (store): { schedule: Schedule } | { status: number; error: string } => {
      const schedule = store.schedules.find((x) => x.id === id); if (!schedule) return { status: 404, error: 'schedule not found' };
      const candidate: Schedule = { ...schedule, ...patch };
      if (worker === null) delete candidate.worker;
      else if (worker) { candidate.worker = worker; candidate.workflowId = ''; }
      const shapeError = scheduleShapeError(candidate); if (shapeError) return { status: 400, error: shapeError };
      if (!validCron(candidate.cron) || !validZone(candidate.timezone)) return { status: 400, error: 'valid five-field cron and IANA timezone are required' };
      // Re-enabling is the operator acknowledging the failure streak.
      if (patch.enabled === true && !schedule.enabled) { candidate.consecutiveFailures = 0; candidate.lastError = undefined; }
      candidate.nextRunAt = previewCron(candidate.cron, candidate.timezone, 1)[0];
      if (worker === null) delete schedule.worker;
      Object.assign(schedule, candidate); return { schedule };
    });
    if ('error' in result) return jsonError(res, result.status, result.error);
    res.json(result.schedule);
  });
  app.post('/api/schedules/:id/run', middleware, writeGuard, async (req, res) => {
    const roots = context(req); const id = String(req.params['id']);
    const recordScope = await findScope(roots, 'schedules', id); if (!recordScope) return jsonError(res, 404, 'schedule not found');
    await refreshAttempts(roots);
    let target = roots;
    if (recordScope === 'global') {
      const schedule = (await readStore(roots, 'global')).schedules.find((s) => s.id === id)!;
      const resolved = schedule.targetWorkspaceRoot ? (await schedulerWorkspaces()).find((w) => sameRoot(w.workspaceRoot, schedule.targetWorkspaceRoot)) : undefined;
      if (!resolved) return jsonError(res, 400, 'global schedules require a registered target project');
      target = resolved;
    }
    const result = await runSchedule(target, recordScope, id, true);
    if (!result.launched) return res.status(409).json({ error: result.reason, schedule: result.schedule });
    res.status(202).json(result.schedule);
  });
}
