/**
 * The only place the dashboard runs `ralph` commands. Every helper spawns
 * with execFile and an argv array (never a shell string), ignores stdin
 * (Ralph CLIs can block on interactive menus when stdin looks like a TTY),
 * and enforces a per-call timeout and output cap.
 */
import { execFile, spawn } from 'node:child_process';
import { closeSync, existsSync, openSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { resolveRalphInstallRoot } from '../paths';

const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_MAX_BUFFER = 8 * 1024 * 1024;
const STDERR_TRUNCATE_BYTES = 4000;

export class RalphCliError extends Error {
  readonly command: string;
  readonly args: readonly string[];
  readonly exitCode: number | null;
  readonly stderr: string;
  readonly timedOut: boolean;

  constructor(options: {
    readonly message: string;
    readonly command: string;
    readonly args: readonly string[];
    readonly exitCode: number | null;
    readonly stderr: string;
    readonly timedOut: boolean;
  }) {
    super(options.message);
    this.name = 'RalphCliError';
    this.command = options.command;
    this.args = options.args;
    this.exitCode = options.exitCode;
    this.stderr = options.stderr;
    this.timedOut = options.timedOut;
  }
}

export interface RunOptions {
  readonly cwd?: string;
  readonly projectRoot?: string;
  /** Ralph state root (`.ralph-workspace` directory). */
  readonly workspaceRoot?: string;
  readonly timeoutMs?: number;
  readonly maxBuffer?: number;
}

/** A currently-running entry from `ralph process list --json`. */
export interface ManagedProcessRun {
  readonly id: string;
  readonly kind: string;
  readonly planPath: string;
  readonly ownerPid: number | null;
  readonly ownerAlive: boolean;
  readonly liveProcesses: number;
  readonly startedAt: string | null;
}

/** Child env for Ralph CLI spawns: explicit roots override stale inherited dashboard values. */
export function buildRalphChildEnv(options: RunOptions = {}): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  const projectRoot = options.projectRoot ?? options.cwd;
  const workspaceRoot = options.workspaceRoot;
  if (projectRoot) {
    env['RALPH_PROJECT_ROOT'] = projectRoot;
  }
  if (workspaceRoot) {
    env['RALPH_PLAN_WORKSPACE_ROOT'] = workspaceRoot;
  }
  return env;
}

function spawnCwd(options: RunOptions): string | undefined {
  return options.cwd ?? options.projectRoot;
}

/**
 * Resolves the `ralph` entrypoint. `RALPH_DASHBOARD_RALPH_BIN` always wins
 * (tests point it at a stub executable). Otherwise `ralph` is resolved via
 * PATH the same way execFile resolves any bare command (no shell involved).
 * If that is not on PATH, fall back to the conventional installer location
 * relative to the framework root the dashboard already resolves for
 * /api/ralph-framework-root, and finally `~/.local/bin/ralph`.
 */
export function resolveRalphBin(): string {
  const override = process.env['RALPH_DASHBOARD_RALPH_BIN']?.trim();
  if (override) {
    return override;
  }
  const installRoot = resolveRalphInstallRoot();
  if (installRoot) {
    const candidate = join(installRoot, 'bin', 'ralph');
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  const homeCandidate = join(homedir(), '.local', 'bin', 'ralph');
  if (existsSync(homeCandidate)) {
    return homeCandidate;
  }
  return 'ralph';
}

function runRalph(args: readonly string[], options: RunOptions = {}): Promise<{ stdout: string; stderr: string }> {
  const bin = resolveRalphBin();
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const maxBuffer = options.maxBuffer ?? DEFAULT_MAX_BUFFER;
  return new Promise((resolvePromise, reject) => {
    const child = execFile(
      bin,
      [...args],
      {
        cwd: spawnCwd(options),
        env: buildRalphChildEnv(options),
        timeout: timeoutMs,
        maxBuffer,
        windowsHide: true,
      },
      (error, stdout, stderr) => {
        if (error) {
          const timedOut = (error as NodeJS.ErrnoException & { killed?: boolean }).killed === true;
          reject(
            new RalphCliError({
              message: `ralph ${args.join(' ')} failed: ${error.message}`,
              command: bin,
              args,
              exitCode: typeof (error as { code?: number }).code === 'number' ? (error as { code: number }).code : null,
              stderr: truncate(stderr ?? ''),
              timedOut,
            }),
          );
          return;
        }
        resolvePromise({ stdout, stderr });
      },
    );
    child.stdin?.end();
  });
}

function truncate(text: string): string {
  return text.length > STDERR_TRUNCATE_BYTES ? `${text.slice(0, STDERR_TRUNCATE_BYTES)}\n...[truncated]` : text;
}

export interface WorkflowListEntry {
  readonly id: string;
  readonly scope: string;
  readonly overview: string;
}

/** `ralph workflow list --tsv` — schema is `<id><TAB><scope><TAB><overview>`. */
export async function listWorkflows(
  options: RunOptions = {},
  listOptions: { readonly allScopes?: boolean } = {},
): Promise<readonly WorkflowListEntry[]> {
  const args = ['workflow', 'list', '--tsv'];
  if (listOptions.allScopes) {
    args.push('--all-scopes');
  }
  const { stdout } = await runRalph(args, options);
  return parseWorkflowListTsv(stdout);
}

/** Every `(id, scope)` row from `ralph workflow list --tsv --all-scopes`. */
export async function listWorkflowsAllScopes(options: RunOptions = {}): Promise<readonly WorkflowListEntry[]> {
  return listWorkflows(options, { allScopes: true });
}

function parseWorkflowListTsv(stdout: string): readonly WorkflowListEntry[] {
  return stdout
    .split('\n')
    .map((line) => line.trimEnd())
    .filter((line) => line.length > 0)
    .map((line) => {
      const [id = '', scope = '', overview = ''] = line.split('\t');
      return { id, scope, overview };
    });
}

export type WorkflowScope = 'project' | 'global' | 'bundled';

function scopeFlag(scope?: WorkflowScope): readonly string[] {
  return scope ? [`--${scope}`] : [];
}

/** `ralph workflow show <id>` — byte-exact file contents. */
export async function showWorkflow(id: string, scope?: WorkflowScope, options: RunOptions = {}): Promise<string> {
  const { stdout } = await runRalph(['workflow', 'show', id, ...scopeFlag(scope)], options);
  return stdout;
}

/** `ralph workflow path <id>` — absolute path of the winning (or scoped) file. */
export async function workflowPath(id: string, scope?: WorkflowScope, options: RunOptions = {}): Promise<string> {
  const { stdout } = await runRalph(['workflow', 'path', id, ...scopeFlag(scope)], options);
  return stdout.trim();
}

export type InspectFormat = 'json' | 'mermaid';

export interface InspectTarget {
  readonly id?: string;
  readonly file?: string;
  readonly scope?: WorkflowScope;
}

/** `ralph workflow inspect (<id> | --file <path>) --format <fmt>` — read-only validate/preview. */
export async function inspectWorkflow(
  target: InspectTarget,
  format: InspectFormat,
  options: RunOptions = {},
): Promise<string> {
  const args = ['workflow', 'inspect'];
  if (target.file) {
    args.push('--file', target.file);
  } else if (target.id) {
    args.push(target.id);
  } else {
    throw new RalphCliError({
      message: 'inspectWorkflow requires target.id or target.file',
      command: resolveRalphBin(),
      args,
      exitCode: null,
      stderr: '',
      timedOut: false,
    });
  }
  args.push('--format', format, ...scopeFlag(target.scope));
  const { stdout } = await runRalph(args, options);
  return stdout;
}

export interface ListRunsQuery {
  readonly workflow?: string;
  readonly state?: string;
  readonly limit?: number;
  readonly all?: boolean;
}

/** `ralph workflow runs --json [--workflow ...] [--state ...] [--limit ...] [--all]` */
export async function listRuns(query: ListRunsQuery = {}, options: RunOptions = {}): Promise<unknown> {
  const args = ['workflow', 'runs', '--json'];
  if (query.workflow) args.push('--workflow', query.workflow);
  if (query.state) args.push('--state', query.state);
  if (typeof query.limit === 'number') args.push('--limit', String(query.limit));
  if (query.all) args.push('--all');
  const { stdout } = await runRalph(args, options);
  return JSON.parse(stdout);
}

/** `ralph workflow status <run-id> --json` */
export async function runStatus(runId: string, options: RunOptions = {}): Promise<unknown> {
  const { stdout } = await runRalph(['workflow', 'status', runId, '--json'], options);
  return JSON.parse(stdout);
}

/** Read the public, supervisor-selected log stream for one workflow stage attempt. */
export async function workflowStageLogs(
  runId: string,
  stageId: string,
  attempt: number,
  options: RunOptions = {},
): Promise<string> {
  const { stdout } = await runRalph(
    ['workflow', 'logs', runId, '--stage', stageId, '--attempt', String(attempt), '--stream', 'combined', '--no-follow', '--color', 'never'],
    options,
  );
  return stdout;
}

/** `ralph list plans` — plain-text table; returns the absolute plan file paths, one per line, in listed order. No --json/--tsv flag exists. */
export async function listPlans(options: RunOptions = {}): Promise<readonly string[]> {
  const { stdout } = await runRalph(['list', 'plans'], options);
  return stdout
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('/'));
}

/** `ralph process list --json` for the explicitly selected project and state roots. */
export async function listManagedProcessRuns(options: RunOptions = {}): Promise<readonly ManagedProcessRun[]> {
  const { stdout } = await runRalph(['process', 'list', '--json', ...rootArgs(options)], options);
  return parseManagedProcessRuns(stdout);
}

/** Stop exactly one registry run; callers must never substitute a plan path here. */
export async function stopManagedProcessRun(runId: string, options: RunOptions = {}): Promise<void> {
  await runRalph(['process', 'stop', '--run', runId, ...rootArgs(options)], options);
}

function rootArgs(options: RunOptions): readonly string[] {
  const projectRoot = options.projectRoot ?? options.cwd;
  const args: string[] = [];
  if (projectRoot) args.push('--workspace', projectRoot);
  if (options.workspaceRoot) args.push('--workspace-root', options.workspaceRoot);
  return args;
}

/** Exported for narrow parser tests; malformed registry rows are intentionally ignored. */
export function parseManagedProcessRuns(stdout: string): readonly ManagedProcessRun[] {
  const parsed: unknown = JSON.parse(stdout);
  if (!Array.isArray(parsed)) return [];
  return parsed.flatMap((value): ManagedProcessRun[] => {
    if (!value || typeof value !== 'object') return [];
    const row = value as Record<string, unknown>;
    const id = typeof row['run_id'] === 'string' ? row['run_id'] : '';
    const kind = typeof row['kind'] === 'string' ? row['kind'] : '';
    const planPath = typeof row['plan_path'] === 'string' ? row['plan_path'] : '';
    if (!id || !kind || !planPath) return [];
    return [{
      id,
      kind,
      planPath,
      ownerPid: typeof row['owner_pid'] === 'number' ? row['owner_pid'] : null,
      ownerAlive: row['owner_alive'] === true,
      liveProcesses: typeof row['live_processes'] === 'number' && row['live_processes'] >= 0 ? row['live_processes'] : 0,
      startedAt: typeof row['started_at'] === 'string' ? row['started_at'] : null,
    }];
  });
}

/** `ralph safety status --json` */
export async function safetyStatus(options: RunOptions = {}): Promise<unknown> {
  const { stdout } = await runRalph(['safety', 'status', '--json'], options);
  return JSON.parse(stdout);
}

/** `ralph safety validate --file <path>` — throws RalphCliError carrying stderr on failure. */
export async function safetyValidateFile(filePath: string, options: RunOptions = {}): Promise<void> {
  await runRalph(['safety', 'validate', '--file', filePath], options);
}

/**
 * `ralph safety check --command <text> --json` — classifies command text only;
 * Ralph does not execute the supplied command. Text is passed as an argv
 * element (never through a shell).
 */
export async function safetyCheckCommand(command: string, options: RunOptions = {}): Promise<unknown> {
  const { stdout } = await runRalph(['safety', 'check', '--command', command, '--json'], options);
  return JSON.parse(stdout);
}

/** `ralph workflow actions list <run-id> --json` */
export async function listActions(runId: string, options: RunOptions = {}): Promise<unknown> {
  const { stdout } = await runRalph(['workflow', 'actions', 'list', runId, '--json'], options);
  return JSON.parse(stdout);
}

export interface RespondActionRequest {
  readonly runId: string;
  readonly requestId: string;
  readonly decision: 'approve' | 'request-changes' | 'cancel' | 'answer';
  readonly message?: string;
}

/** `ralph workflow actions respond <run-id> <request-id> --decision <d> [--message <m>] --yes` */
export async function respondAction(request: RespondActionRequest, options: RunOptions = {}): Promise<void> {
  const args = ['workflow', 'actions', 'respond', request.runId, request.requestId, '--decision', request.decision, '--yes'];
  if (request.message) {
    args.push('--message', request.message);
  }
  await runRalph(args, options);
}

/** `ralph workflow cancel <run-id>` */
export async function cancelRun(runId: string, options: RunOptions = {}): Promise<void> {
  await runRalph(['workflow', 'cancel', runId], options);
}

/** `ralph workflow resume <run-id>` */
export async function resumeRun(runId: string, options: RunOptions = {}): Promise<void> {
  await runRalph(['workflow', 'resume', runId], options);
}

export interface ResetRunRequest {
  readonly runId: string;
  readonly stage?: string;
  readonly all?: boolean;
}

/** `ralph workflow reset <run-id> (--stage <id>|--all) --yes` */
export async function resetRun(request: ResetRunRequest, options: RunOptions = {}): Promise<void> {
  const args = ['workflow', 'reset', request.runId, '--yes'];
  if (request.all) {
    args.push('--all');
  } else if (request.stage) {
    args.push('--stage', request.stage);
  }
  await runRalph(args, options);
}

/** `<bundle-path>/models.sh list <runtime>` — one model id per line. */
export async function listModels(runtime: string, options: RunOptions = {}): Promise<readonly string[]> {
  const { stdout: bundlePath } = await runRalph(['--bundle-path'], options);
  const modelsSh = join(bundlePath.trim(), 'models.sh');
  const bin = process.env['RALPH_DASHBOARD_MODELS_SH_BIN']?.trim() || modelsSh;
  return new Promise((resolvePromise, reject) => {
    const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    const maxBuffer = options.maxBuffer ?? DEFAULT_MAX_BUFFER;
    const child = execFile(
      bin,
      ['list', runtime],
      {
        cwd: spawnCwd(options),
        env: buildRalphChildEnv(options),
        timeout: timeoutMs,
        maxBuffer,
        windowsHide: true,
      },
      (error, stdout, stderr) => {
        if (error) {
          reject(
            new RalphCliError({
              message: `models.sh list ${runtime} failed: ${error.message}`,
              command: bin,
              args: ['list', runtime],
              exitCode: typeof (error as { code?: number }).code === 'number' ? (error as { code: number }).code : null,
              stderr: truncate(stderr ?? ''),
              timedOut: (error as { killed?: boolean }).killed === true,
            }),
          );
          return;
        }
        resolvePromise(
          stdout
            .split('\n')
            .map((line) => line.trim())
            .filter((line) => line.length > 0),
        );
      },
    );
    child.stdin?.end();
  });
}

export const SUPPORTED_RUNTIMES = ['cursor', 'claude', 'codex', 'opencode', 'antigravity'] as const;
export type SupportedRuntime = (typeof SUPPORTED_RUNTIMES)[number];

export const RUNTIME_BINARY_NAMES: Record<SupportedRuntime, readonly string[]> = {
  cursor: ['cursor-agent'],
  claude: ['claude'],
  codex: ['codex'],
  opencode: ['opencode'],
  antigravity: ['agy', 'antigravity'],
};

function pathDirectories(): readonly string[] {
  return (process.env['PATH'] ?? '').split(process.platform === 'win32' ? ';' : ':').filter(Boolean);
}

/**
 * First binary name for `runtime` found on PATH, or null. No shell; probes
 * PATH directories directly. Tests point `RALPH_DASHBOARD_RUNTIME_BIN_<ID>`
 * (e.g. RALPH_DASHBOARD_RUNTIME_BIN_CLAUDE) at a stub executable to select
 * it without touching the real PATH or invoking a real runtime.
 */
export function resolveRuntimeBinary(runtime: SupportedRuntime): string | null {
  const override = process.env[`RALPH_DASHBOARD_RUNTIME_BIN_${runtime.toUpperCase()}`]?.trim();
  if (override) {
    return override;
  }
  const dirs = pathDirectories();
  return RUNTIME_BINARY_NAMES[runtime].find((name) => dirs.some((dir) => existsSync(join(dir, name)))) ?? null;
}

/** PATH lookup for each supported runtime's binary. No shell; execFile('which'|'where', ...) not used — probes PATH directories directly. */
export async function installedRuntimes(): Promise<Record<SupportedRuntime, boolean>> {
  const result = {} as Record<SupportedRuntime, boolean>;
  for (const runtime of SUPPORTED_RUNTIMES) {
    result[runtime] = resolveRuntimeBinary(runtime) !== null;
  }
  return result;
}

export interface StartWorkflowRequest {
  readonly id: string;
  /** Single-line inline request. Ralph rejects embedded newlines. */
  readonly task?: string;
  /** Multi-line request file passed as `--plan`. It must contain no Ralph TODOs
   * and live under the project or state root; Ralph uses its content as the task. */
  readonly taskFile?: string;
  readonly runtime?: string;
  readonly model?: string;
}

export interface DetachedProcessHandle {
  readonly pid: number;
  readonly logPath: string;
}

/**
 * Spawns `ralph workflow start <id> (--task <text> | --plan <file>) --yes [--runtime][--model]`
 * detached in its own process group, stdio redirected to `logPath`, and
 * unref'd so the caller's process can exit without waiting for it. Ralph's
 * own TTY guards (see port-design.md "ralph workflow start non-blocking
 * confirmation") make this safe with stdin closed: `--yes` skips every
 * prompt, and no stdout TTY means the interactive viewer never attaches, so
 * the child runs the workflow to completion synchronously under its own
 * detached process rather than blocking on operator input.
 */
export function startWorkflowDetached(request: StartWorkflowRequest, logPath: string, options: RunOptions = {}): DetachedProcessHandle {
  const bin = resolveRalphBin();
  const args = request.taskFile
    ? ['workflow', 'start', request.id, '--plan', request.taskFile, '--yes']
    : ['workflow', 'start', request.id, '--task', request.task ?? '', '--yes'];
  if (request.runtime) {
    args.push('--runtime', request.runtime);
  }
  if (request.model) {
    args.push('--model', request.model);
  }
  const fd = openSync(logPath, 'a');
  try {
    const child = spawn(bin, args, {
      cwd: spawnCwd(options),
      env: buildRalphChildEnv(options),
      stdio: ['ignore', fd, fd],
      detached: true,
      windowsHide: true,
    });
    child.unref();
    if (typeof child.pid !== 'number') {
      throw new RalphCliError({
        message: 'Failed to spawn ralph workflow start: no pid assigned',
        command: bin,
        args,
        exitCode: null,
        stderr: '',
        timedOut: false,
      });
    }
    return { pid: child.pid, logPath };
  } finally {
    closeSync(fd);
  }
}

/** Start a leaf TODO loop without wrapping it in a workflow registry run. */
export function runPlanDetached(planPath: string, logPath: string, options: RunOptions = {}): DetachedProcessHandle {
  const bin = resolveRalphBin();
  const args = ['run', '--plan', planPath];
  const fd = openSync(logPath, 'a');
  try {
    const child = spawn(bin, args, {
      cwd: spawnCwd(options), env: buildRalphChildEnv(options), stdio: ['ignore', fd, fd], detached: true, windowsHide: true,
    });
    child.unref();
    if (typeof child.pid !== 'number') throw new RalphCliError({ message: 'Failed to spawn ralph run: no pid assigned', command: bin, args, exitCode: null, stderr: '', timedOut: false });
    return { pid: child.pid, logPath };
  } finally { closeSync(fd); }
}

export interface WorkflowRoutingPatch {
  readonly sha256: string;
  readonly defaults?: {
    readonly runtime?: string | null;
    readonly model?: string | null;
    readonly clear?: boolean;
  } | null;
  readonly stages?: Readonly<Record<string, { readonly runtime?: string | null; readonly model?: string | null; readonly clear?: boolean } | null>>;
}

/** `ralph workflow routing set` — returns the new workflow sha256 (stdout). */
export async function setWorkflowRouting(
  id: string,
  scope: 'project' | 'global',
  patch: WorkflowRoutingPatch,
  options: RunOptions = {},
): Promise<string> {
  const args: string[] = ['workflow', 'routing', 'set', id, `--${scope}`, '--sha256', patch.sha256];

  if (patch.defaults === null) {
    args.push('--clear-defaults');
  } else if (patch.defaults) {
    if (patch.defaults.clear) {
      args.push('--clear-defaults');
    }
    if (patch.defaults.runtime === null) {
      args.push('--clear-default-runtime');
    } else if (typeof patch.defaults.runtime === 'string' && patch.defaults.runtime.length > 0) {
      args.push('--default-runtime', patch.defaults.runtime);
    }
    if (patch.defaults.model === null) {
      args.push('--clear-default-model');
    } else if (typeof patch.defaults.model === 'string' && patch.defaults.model.length > 0) {
      args.push('--default-model', patch.defaults.model);
    }
  }

  if (patch.stages) {
    for (const [stageId, stagePatch] of Object.entries(patch.stages)) {
      if (stagePatch === null || stagePatch.clear) {
        args.push('--clear-stage', stageId);
        continue;
      }
      if (stagePatch.runtime === null && stagePatch.model === null) {
        args.push('--clear-stage', stageId);
        continue;
      }
      if (stagePatch.runtime === null) {
        args.push('--clear-stage', stageId);
      } else if (stagePatch.model === null) {
        if (typeof stagePatch.runtime === 'string') {
          args.push('--stage', `${stageId}=${stagePatch.runtime}`);
        }
        args.push('--clear-stage-model', stageId);
      } else if (typeof stagePatch.runtime === 'string') {
        const modelPart = typeof stagePatch.model === 'string' ? `,${stagePatch.model}` : '';
        args.push('--stage', `${stageId}=${stagePatch.runtime}${modelPart}`);
      } else if (typeof stagePatch.model === 'string') {
        args.push('--stage-model', `${stageId}=${stagePatch.model}`);
      }
    }
  }

  const { stdout } = await runRalph(args, options);
  return stdout.trim();
}
