import { randomBytes, createHash } from 'node:crypto';
import { existsSync, promises as fs } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import type { Express, Request, RequestHandler, Response } from 'express';
import { findDashboardRoots, type DashboardRoots, resolveRalphInstallRoot } from '../paths';
import { getMergedWorkspaceAllowlist } from './dashboard-api';
import { resolveDashboardRootsForWorkspaceRoot } from './dashboard-workspace-resolve';
import {
  cancelRun,
  installedRuntimes,
  inspectWorkflow,
  listActions,
  listModels,
  listRuns,
  listWorkflows,
  listWorkflowsAllScopes,
  resetRun,
  respondAction,
  resumeRun,
  runStatus,
  workflowStageLogs,
  showWorkflow,
  startWorkflowDetached,
  setWorkflowRouting,
  type WorkflowRoutingPatch,
  workflowPath,
  RalphCliError,
  type RunOptions,
  type WorkflowScope,
} from './ralph-cli';
import {
  deriveInheritRef,
  deriveWorkflowCatalogMeta,
  emptyWorkflowCatalogMeta,
} from './workflow-catalog';
import {
  buildDisplayGraphError,
  buildDisplayGraphFromInspect,
} from './workflow-display-graph';
import { enrichWorkflowRunDetail } from './workflow-run-detail';
import {
  emitWorkflowFrontmatter,
  parseWorkflowFrontmatter,
  WorkflowFrontmatterError,
  type WorkflowFrontmatterModel,
} from './workflow-frontmatter';
import { formatValidationIssues, validateWorkflowModel } from './workflow-frontmatter-validate';
import { writeGuard } from './write-guard';
import { cachedWorkflowRead, workflowReadFingerprint } from './workflow-read-cache';
import {
  availableScopesForId,
  effectiveScopeForId,
  parseWorkflowScopeQuery,
  shadowedByScope,
  type WorkflowScopeEntry,
} from './workflow-scope';

const WORKFLOW_ID_PATTERN = /^[a-z0-9]+(-[a-z0-9]+)*$/;
/**
 * Observed shape: `run-<basicISOTimestamp>Z-<n>-<base62>`, e.g.
 * `run-20260910T015232Z-0-PzuPyc`. Kept loose (prefix + safe charset) rather
 * than pinned to that exact grammar, since the format is not a documented
 * contract — see port-design.md "API" for the verification note.
 */
const RUN_ID_PATTERN = /^run-[A-Za-z0-9-]+$/;
const RUNTIME_PATTERN = /^[a-z0-9-]+$/;

function jsonError(res: Response, status: number, message: string): void {
  res.status(status).json({ error: message });
}

function isValidWorkflowId(id: string): boolean {
  return WORKFLOW_ID_PATTERN.test(id);
}

function isValidRunId(id: string): boolean {
  return RUN_ID_PATTERN.test(id);
}

type WorkflowRequest = Request & { ralphWorkflowWorkspace?: DashboardRoots };

function attachWorkflowContext(req: Request, res: Response, roots: DashboardRoots): void {
  res.locals['ralphWorkflowWorkspace'] = roots;
  (req as WorkflowRequest).ralphWorkflowWorkspace = roots;
}

function workflowWorkspace(req: Request, res: Response): DashboardRoots {
  const context =
    (res.locals as { ralphWorkflowWorkspace?: DashboardRoots }).ralphWorkflowWorkspace ??
    (req as WorkflowRequest).ralphWorkflowWorkspace;
  if (!context) {
    throw new Error('workflow workspace context missing');
  }
  return context;
}

function runOptions(req: Request, res: Response): RunOptions {
  const context = workflowWorkspace(req, res);
  return {
    cwd: context.projectRoot,
    projectRoot: context.projectRoot,
    workspaceRoot: context.workspaceRoot,
  };
}

const workflowWorkspaceMiddleware: RequestHandler = async (req, res, next) => {
  try {
    const query = typeof req.query['workspaceRoot'] === 'string' ? req.query['workspaceRoot'].trim() : '';
    const allowlist = await getMergedWorkspaceAllowlist();
    const roots = query ? resolveDashboardRootsForWorkspaceRoot(query, allowlist) : findDashboardRoots();
    if (roots === null) {
      jsonError(res, 400, 'invalid workspaceRoot');
      return;
    }
    attachWorkflowContext(req, res, roots);
    next();
  } catch (error: unknown) {
    jsonError(res, 500, error instanceof Error ? error.message : 'workspace resolution failed');
  }
};

/** Project scope: `<state-root>/workflows/`. Global scope: `${RALPH_HOME:-$HOME/.ralph}/workflows/`. Mirrors docs/WORKFLOWS.md "Resolution and editing". */
function scopeDir(scope: 'project' | 'global', context: DashboardRoots): string {
  if (scope === 'project') {
    return join(context.workspaceRoot, 'workflows');
  }
  const globalHome = resolveRalphInstallRoot() ?? join(homedir(), '.ralph');
  return join(globalHome, 'workflows');
}

function workflowFilePath(dir: string, id: string): string {
  return join(dir, `${id}.workflow.md`);
}

/**
 * Writes `content` to a temp file beside `targetPath` (same directory, so the
 * final rename is atomic on the same filesystem), validates it with
 * `ralph workflow inspect --file <tmp>`, deletes the temp file on every path,
 * and renames into place only on success. Returns the inspect failure text
 * on 422, leaving `targetPath` byte-identical to before the call.
 */
async function writeValidated(
  targetPath: string,
  content: string,
  options: RunOptions,
): Promise<{ ok: true } | { ok: false; diagnostics: string }> {
  const dir = dirname(targetPath);
  await fs.mkdir(dir, { recursive: true });
  const tmpPath = join(dir, `.${basename(targetPath)}.tmp-${randomBytes(6).toString('hex')}`);
  try {
    await fs.writeFile(tmpPath, content, 'utf8');
    try {
      await inspectWorkflow({ file: tmpPath }, 'json', options);
    } catch (error: unknown) {
      const diagnostics = error instanceof RalphCliError ? error.stderr || error.message : error instanceof Error ? error.message : 'validation failed';
      return { ok: false, diagnostics };
    }
    await fs.rename(tmpPath, targetPath);
    return { ok: true };
  } finally {
    await fs.unlink(tmpPath).catch(() => undefined);
  }
}

function sha256Hex(content: string): string {
  return createHash('sha256').update(content, 'utf8').digest('hex');
}

/**
 * Validates and publishes a new workflow file. Never overwrites an existing target;
 * returns `created: false` with the on-disk sha256 when the target appeared first
 * (idempotent customize or concurrent create race).
 */
async function writeValidatedCreate(
  targetPath: string,
  content: string,
  options: RunOptions,
): Promise<{ ok: true; created: true; sha256: string } | { ok: true; created: false; sha256: string } | { ok: false; diagnostics: string }> {
  if (existsSync(targetPath)) {
    const existing = await fs.readFile(targetPath, 'utf8');
    return { ok: true, created: false, sha256: sha256Hex(existing) };
  }
  const dir = dirname(targetPath);
  await fs.mkdir(dir, { recursive: true });
  const tmpPath = join(dir, `.${basename(targetPath)}.tmp-${randomBytes(6).toString('hex')}`);
  let published = false;
  try {
    await fs.writeFile(tmpPath, content, 'utf8');
    try {
      await inspectWorkflow({ file: tmpPath }, 'json', options);
    } catch (error: unknown) {
      const diagnostics = error instanceof RalphCliError ? error.stderr || error.message : error instanceof Error ? error.message : 'validation failed';
      return { ok: false, diagnostics };
    }
    if (existsSync(targetPath)) {
      const existing = await fs.readFile(targetPath, 'utf8');
      return { ok: true, created: false, sha256: sha256Hex(existing) };
    }
    await fs.rename(tmpPath, targetPath);
    published = true;
    return { ok: true, created: true, sha256: sha256Hex(content) };
  } finally {
    if (!published) {
      await fs.unlink(tmpPath).catch(() => undefined);
    }
  }
}

function isWritableScope(scope: string): scope is 'project' | 'global' {
  return scope === 'project' || scope === 'global';
}

/**
 * Builds a WorkflowFrontmatterModel from a client-supplied wire object,
 * trusting shape (`ralph workflow inspect` is the validator of record).
 * Wire shape matches port-design.md's API table: `defaults: {runtime,
 * model}` and `pipeline: {maxParallel, maxReworkIterations, stages}` are
 * nested, same as the frontmatter itself and as GET /api/workflows/:id's
 * `model` field the client edits and sends back.
 */
export function modelFromWire(wire: Record<string, unknown>, sourceRaw: string, body: string): WorkflowFrontmatterModel {
  const defaults = (wire['defaults'] && typeof wire['defaults'] === 'object' ? wire['defaults'] : {}) as Record<string, unknown>;
  const pipeline = (wire['pipeline'] && typeof wire['pipeline'] === 'object' ? wire['pipeline'] : {}) as Record<string, unknown>;
  // Also accept the flattened GET /api/workflows/:id "model" shape, where
  // these fields already live at the top level (defaultsRuntime,
  // defaultsModel, maxParallel, maxReworkIterations, stages, todos).
  const defaultsRuntime = typeof wire['defaultsRuntime'] === 'string' ? wire['defaultsRuntime'] : typeof defaults['runtime'] === 'string' ? defaults['runtime'] : undefined;
  const defaultsModel = typeof wire['defaultsModel'] === 'string' ? wire['defaultsModel'] : typeof defaults['model'] === 'string' ? defaults['model'] : undefined;
  const maxParallel = typeof wire['maxParallel'] === 'number' ? wire['maxParallel'] : typeof pipeline['maxParallel'] === 'number' ? pipeline['maxParallel'] : undefined;
  const maxReworkIterations =
    typeof wire['maxReworkIterations'] === 'number' ? wire['maxReworkIterations'] : typeof pipeline['maxReworkIterations'] === 'number' ? pipeline['maxReworkIterations'] : undefined;
  const publishMode =
    typeof wire['publishMode'] === 'string' ? wire['publishMode'] : typeof pipeline['publishMode'] === 'string' ? pipeline['publishMode'] : undefined;
  const verificationProfiles = Array.isArray(wire['verificationProfiles'])
    ? (wire['verificationProfiles'] as WorkflowFrontmatterModel['verificationProfiles'])
    : Array.isArray(pipeline['verificationProfiles'])
      ? (pipeline['verificationProfiles'] as WorkflowFrontmatterModel['verificationProfiles'])
      : undefined;
  const planInput =
    wire['planInput'] && typeof wire['planInput'] === 'object'
      ? (wire['planInput'] as WorkflowFrontmatterModel['planInput'])
      : undefined;
  const stagesSource = Array.isArray(wire['stages']) ? wire['stages'] : Array.isArray(pipeline['stages']) ? pipeline['stages'] : [];
  return {
    name: typeof wire['name'] === 'string' ? wire['name'] : undefined,
    overview: typeof wire['overview'] === 'string' ? wire['overview'] : undefined,
    kind: typeof wire['kind'] === 'string' ? wire['kind'] : 'workflow',
    mode: typeof wire['mode'] === 'string' ? wire['mode'] : undefined,
    defaultsRuntime,
    defaultsModel,
    ...(planInput !== undefined ? { planInput } : {}),
    maxParallel,
    maxReworkIterations,
    ...(publishMode !== undefined ? { publishMode } : {}),
    ...(verificationProfiles !== undefined ? { verificationProfiles } : {}),
    stages: stagesSource as WorkflowFrontmatterModel['stages'],
    todos: Array.isArray(wire['todos']) ? (wire['todos'] as WorkflowFrontmatterModel['todos']) : [],
    unsupportedKeys: Array.isArray(wire['unsupportedKeys']) ? (wire['unsupportedKeys'] as string[]) : [],
    body,
    sourceRaw,
  };
}

function handleCliError(res: Response, error: unknown, notFoundMessage: string): void {
  if (error instanceof RalphCliError) {
    if (/not found|no such workflow|unknown workflow/i.test(error.stderr) || /not found|no such workflow|unknown workflow/i.test(error.message)) {
      jsonError(res, 404, notFoundMessage);
      return;
    }
    jsonError(res, 502, error.stderr || error.message);
    return;
  }
  jsonError(res, 502, error instanceof Error ? error.message : 'ralph command failed');
}

/**
 * Both listings come from the Ralph CLI and are cached against a filesystem
 * fingerprint of the scope directories. The fingerprint is returned so a
 * single request reuses it for its `show`/`inspect` reads instead of
 * re-statting the same files.
 */
async function loadWorkflowScopeIndex(
  options: RunOptions,
): Promise<{
  readonly winners: Awaited<ReturnType<typeof listWorkflows>>;
  readonly allScopes: Awaited<ReturnType<typeof listWorkflowsAllScopes>>;
  readonly fingerprint: string;
}> {
  const workspaceRoot = options.workspaceRoot ?? '';
  const fingerprint = workflowReadFingerprint(workspaceRoot);
  const [winners, allScopes] = await Promise.all([
    cachedWorkflowRead(`list-winners|${workspaceRoot}`, fingerprint, () => listWorkflows(options)),
    cachedWorkflowRead(`list-all|${workspaceRoot}`, fingerprint, () => listWorkflowsAllScopes(options)),
  ]);
  return { winners, allScopes, fingerprint };
}

/** Cache key for one resolved definition's `ralph workflow show` output. */
function showCacheKey(workspaceRoot: string, id: string, scope: string): string {
  return `show|${workspaceRoot}|${id}|${scope}`;
}

function scopeMetadataForId(
  allScopes: readonly { id: string; scope: string; overview: string }[],
  id: string,
  winnerScope: string,
): { readonly effectiveScope: string; readonly availableScopes: readonly WorkflowScopeEntry[] } {
  const availableScopes = availableScopesForId(allScopes, id);
  const effectiveScope = effectiveScopeForId(allScopes, id) ?? winnerScope;
  return { effectiveScope, availableScopes };
}

async function handleListWorkflows(req: Request, res: Response): Promise<void> {
  try {
    const options = runOptions(req, res);
    const workspaceRoot = options.workspaceRoot ?? '';
    const { winners, allScopes, fingerprint } = await loadWorkflowScopeIndex(options);
    const enriched = await Promise.all(
      winners.map(async (row) => {
        const meta = scopeMetadataForId(allScopes, row.id, row.scope);
        const effectiveScope = meta.effectiveScope;
        let catalog = emptyWorkflowCatalogMeta(row.overview);
        try {
          const raw = await cachedWorkflowRead(
            showCacheKey(workspaceRoot, row.id, effectiveScope),
            fingerprint,
            () => showWorkflow(row.id, effectiveScope as WorkflowScope, options),
          );
          catalog = deriveWorkflowCatalogMeta(raw, row.overview);
        } catch {
          // List stays usable when a single definition cannot be shown/parsed.
        }
        return {
          id: row.id,
          scope: row.scope,
          effectiveScope,
          availableScopes: meta.availableScopes,
          overview: row.overview,
          editable: effectiveScope !== 'bundled',
          catalog,
          inheritsFrom: deriveInheritRef(effectiveScope, meta.availableScopes),
        };
      }),
    );
    const includeAuto = req.query['includeAuto'] === '1';
    // Dashboard task assignment has one virtual workflow: Auto is a guarded
    // triage pass that routes a task to a real installed workflow. It is not
    // a Ralph-authored definition and therefore is intentionally read-only.
    res.json([
      ...(includeAuto ? [
      {
        id: 'auto',
        scope: 'project',
        effectiveScope: 'project',
        availableScopes: [],
        overview: 'Review the task with triage, then assign the recommended installed workflow. No implementation runs during routing.',
        editable: false,
        catalog: {
          purpose: 'Route a task to the best installed workflow after read-only review.',
          expectedOutcome: 'A ready task with a recommended workflow and triage evidence.',
          mode: 'dashboard',
          stageCount: 1,
          executableStageCount: 1,
          supervisorStageCount: 0,
          requiresSuppliedPlan: false,
          writes: false,
          hasHumanGates: false,
        },
        inheritsFrom: null,
      },
      ] : []),
      ...enriched,
    ]);
  } catch (error: unknown) {
    handleCliError(res, error, 'workflows not found');
  }
}

async function handleGetWorkflow(req: Request, res: Response): Promise<void> {
  const id = String(req.params['id'] ?? '');
  if (!isValidWorkflowId(id)) {
    jsonError(res, 400, 'Invalid workflow id');
    return;
  }
  const scopeQuery = parseWorkflowScopeQuery(req.query['scope']);
  if (req.query['scope'] !== undefined && scopeQuery === undefined) {
    jsonError(res, 400, 'scope must be "project", "global", or "bundled"');
    return;
  }
  const options = runOptions(req, res);
  try {
    const workspaceRoot = options.workspaceRoot ?? '';
    const { winners, allScopes, fingerprint } = await loadWorkflowScopeIndex(options);
    const availableScopes = availableScopesForId(allScopes, id);
    if (availableScopes.length === 0) {
      jsonError(res, 404, `Workflow "${id}" not found`);
      return;
    }
    const effectiveScope = effectiveScopeForId(allScopes, id) ?? winners.find((entry) => entry.id === id)?.scope;
    if (!effectiveScope) {
      jsonError(res, 404, `Workflow "${id}" not found`);
      return;
    }
    const activeScope = scopeQuery ?? effectiveScope;
    if (!availableScopes.some((entry) => entry.scope === activeScope)) {
      jsonError(res, 404, `Workflow "${id}" not found in ${activeScope} scope`);
      return;
    }
    const scopeArg = activeScope as WorkflowScope;
    let raw: string;
    try {
      raw = await cachedWorkflowRead(showCacheKey(workspaceRoot, id, scopeArg), fingerprint, () =>
        showWorkflow(id, scopeArg, options),
      );
    } catch (error: unknown) {
      handleCliError(res, error, `Workflow "${id}" not found`);
      return;
    }
    const sha256 = createHash('sha256').update(raw, 'utf8').digest('hex');
    const parsed = parseWorkflowFrontmatter(raw);
    const body: Record<string, unknown> = {
      id,
      scope: activeScope,
      effectiveScope,
      availableScopes,
      origin: {
        kind: activeScope,
        projectRoot: activeScope === 'project' ? workflowWorkspace(req, res).projectRoot : null,
        workspaceRoot: activeScope === 'project' ? workflowWorkspace(req, res).workspaceRoot : null,
        sourcePath: null,
      },
      raw,
      sha256,
    };
    const shadowedBy = shadowedByScope(effectiveScope as WorkflowScope, activeScope as WorkflowScope);
    if (shadowedBy) {
      body['shadowedBy'] = shadowedBy;
    }
    if (parsed.ok) {
      if (parsed.model.unsupportedKeys.length === 0) {
        body['model'] = parsed.model;
      } else {
        body['unsupportedKeys'] = parsed.model.unsupportedKeys;
      }
    } else {
      body['unsupportedKeys'] = [];
      body['parseError'] = parsed.error.message;
    }

    let inspect: unknown = null;
    let mermaid = '';
    try {
      const [inspectJsonText, mermaidText] = await Promise.all([
        cachedWorkflowRead(`inspect-json|${workspaceRoot}|${id}|${scopeArg}`, fingerprint, () =>
          inspectWorkflow({ id, scope: scopeArg }, 'json', options),
        ),
        cachedWorkflowRead(`inspect-mermaid|${workspaceRoot}|${id}|${scopeArg}`, fingerprint, () =>
          inspectWorkflow({ id, scope: scopeArg }, 'mermaid', options),
        ),
      ]);
      mermaid = mermaidText;
      inspect = JSON.parse(inspectJsonText);
      const inspectedSource =
        inspect && typeof inspect === 'object'
          ? (inspect as { source?: { path?: unknown } }).source
          : undefined;
      if (typeof inspectedSource?.path === 'string') {
        (body['origin'] as { sourcePath: string | null }).sourcePath = inspectedSource.path;
      }
      body['inspect'] = inspect;
      body['mermaid'] = mermaid;
    } catch (error: unknown) {
      const diagnostics =
        error instanceof RalphCliError
          ? error.stderr || error.message
          : error instanceof Error
            ? error.message
            : String(error);
      body['inspect'] = null;
      body['mermaid'] = '';
      body['graphError'] = buildDisplayGraphError({
        code: 'inspect-failed',
        message: `Could not build a display graph for "${id}".`,
        diagnostics,
        sourcePath: null,
        sourceKind: activeScope,
      });
      res.json(body);
      return;
    }

    const inspectSource =
      inspect && typeof inspect === 'object'
        ? (inspect as { source?: { path?: unknown; scope?: unknown } }).source
        : undefined;
    const maxReworkIterations = parsed.ok ? (parsed.model.maxReworkIterations ?? null) : null;
    const graphResult = buildDisplayGraphFromInspect(inspect, {
      workflowId: id,
      maxReworkIterations,
    });
    if (graphResult.ok) {
      body['displayGraph'] = graphResult.graph;
    } else {
      const err = graphResult.error;
      body['graphError'] = {
        ...err,
        sourcePath: err.sourcePath ?? (typeof inspectSource?.path === 'string' ? inspectSource.path : null),
        sourceKind: err.sourceKind ?? (typeof inspectSource?.scope === 'string' ? inspectSource.scope : activeScope),
      };
    }
    res.json(body);
  } catch (error: unknown) {
    handleCliError(res, error, `Workflow "${id}" not found`);
  }
}

async function handleWorkflowRuns(req: Request, res: Response): Promise<void> {
  const id = String(req.params['id'] ?? '');
  if (!isValidWorkflowId(id)) {
    jsonError(res, 400, 'Invalid workflow id');
    return;
  }
  try {
    const runs = await listRuns({ workflow: id }, runOptions(req, res));
    const rows = Array.isArray(runs) ? runs : [];
    res.json(
      rows.map((run) => ({
        ...(run as Record<string, unknown>),
        // No verified 1:1 correspondence between a workflow run id and a
        // `.ralph-workspace/graph-runs/<namespace>` directory for every run
        // (see port-design.md "API" table) — always null until that is
        // re-verified against a live run.
        graphRunLink: null,
      })),
    );
  } catch (error: unknown) {
    handleCliError(res, error, `Workflow "${id}" not found`);
  }
}

async function handleWorkflowRunsList(req: Request, res: Response): Promise<void> {
  const workflow = typeof req.query['workflow'] === 'string' ? req.query['workflow'] : undefined;
  const state = typeof req.query['state'] === 'string' ? req.query['state'] : undefined;
  if (workflow !== undefined && !isValidWorkflowId(workflow)) {
    jsonError(res, 400, 'Invalid workflow id');
    return;
  }
  try {
    const runs = await listRuns({ workflow, state }, runOptions(req, res));
    res.json(runs);
  } catch (error: unknown) {
    handleCliError(res, error, 'runs not found');
  }
}

async function handleWorkflowRunDetail(req: Request, res: Response): Promise<void> {
  const runId = String(req.params['runId'] ?? '');
  if (!isValidRunId(runId)) {
    jsonError(res, 400, 'Invalid run id');
    return;
  }
  try {
    const options = runOptions(req, res);
    const status = await runStatus(runId, options);
    let actions: unknown = [];
    try {
      actions = await listActions(runId, options);
    } catch {
      // Status remains usable when actions listing fails; detail.actions stays empty.
      actions = [];
    }
    res.json(enrichWorkflowRunDetail(status, actions));
  } catch (error: unknown) {
    handleCliError(res, error, `Run "${runId}" not found`);
  }
}

async function handleWorkflowStageLogs(req: Request, res: Response): Promise<void> {
  const runId = String(req.params['runId'] ?? '');
  const stageId = String(req.params['stageId'] ?? '');
  const attempt = Number.parseInt(String(req.query['attempt'] ?? '1'), 10);
  if (!isValidRunId(runId) || !WORKFLOW_ID_PATTERN.test(stageId) || !Number.isSafeInteger(attempt) || attempt < 1) {
    jsonError(res, 400, 'Invalid workflow stage log target');
    return;
  }
  try {
    const content = await workflowStageLogs(runId, stageId, attempt, runOptions(req, res));
    res.json({ runId, stageId, attempt, content });
  } catch (error: unknown) {
    handleCliError(res, error, `Logs for stage "${stageId}" were not found`);
  }
}

async function handleWorkflowRuntimes(req: Request, res: Response): Promise<void> {
  const installed = await installedRuntimes();
  res.json(
    Object.entries(installed).map(([id, isInstalled]) => ({ id, installed: isInstalled })),
  );
  void req;
}

async function handleWorkflowRuntimeModels(req: Request, res: Response): Promise<void> {
  const runtime = String(req.params['runtime'] ?? '');
  if (!RUNTIME_PATTERN.test(runtime)) {
    jsonError(res, 400, 'Invalid runtime id');
    return;
  }
  try {
    const models = await listModels(runtime, runOptions(req, res));
    res.json(models.map((id) => ({ id, label: id })));
  } catch (error: unknown) {
    handleCliError(res, error, `Runtime "${runtime}" not found`);
  }
}

async function handleCreateWorkflow(req: Request, res: Response): Promise<void> {
  try {
    const body = (req.body ?? {}) as Record<string, unknown>;
    const id = typeof body['id'] === 'string' ? body['id'] : '';
    const scope = typeof body['scope'] === 'string' ? body['scope'] : '';
    if (!isValidWorkflowId(id)) {
      jsonError(res, 400, 'Invalid workflow id');
      return;
    }
    if (!isWritableScope(scope)) {
      jsonError(res, 400, 'scope must be "project" or "global"');
      return;
    }
    const dir = scopeDir(scope, workflowWorkspace(req, res));
    const targetPath = workflowFilePath(dir, id);
    if (existsSync(targetPath)) {
      jsonError(res, 409, `Workflow "${id}" already exists in ${scope} scope`);
      return;
    }
    let content: string;
    try {
      const model = modelFromWire(body, '', '\n');
      const localIssues = validateWorkflowModel(model);
      if (localIssues.length > 0) {
        res.status(422).json({ error: 'Workflow failed validation', diagnostics: formatValidationIssues(localIssues) });
        return;
      }
      content = emitWorkflowFrontmatter(model);
    } catch (error: unknown) {
      jsonError(res, 400, error instanceof WorkflowFrontmatterError ? error.message : 'Invalid workflow model');
      return;
    }
    const result = await writeValidated(targetPath, content, runOptions(req, res));
    if (!result.ok) {
      res.status(422).json({ error: 'Workflow failed validation', diagnostics: result.diagnostics });
      return;
    }
    const sha256 = createHash('sha256').update(content, 'utf8').digest('hex');
    res.status(201).json({ id, scope, sha256 });
  } catch (error: unknown) {
    jsonError(res, 500, error instanceof Error ? error.message : 'create workflow failed');
  }
}

async function handleUpdateWorkflow(req: Request, res: Response): Promise<void> {
  const id = String(req.params['id'] ?? '');
  if (!isValidWorkflowId(id)) {
    jsonError(res, 400, 'Invalid workflow id');
    return;
  }
  const body = (req.body ?? {}) as Record<string, unknown>;
  const clientSha256 = typeof body['sha256'] === 'string' ? body['sha256'] : '';
  if (!clientSha256) {
    jsonError(res, 400, 'sha256 of the loaded file is required');
    return;
  }
  const scopeQuery = parseWorkflowScopeQuery(req.query['scope']);
  if (req.query['scope'] !== undefined && scopeQuery === undefined) {
    jsonError(res, 400, 'scope must be "project", "global", or "bundled"');
    return;
  }
  const options = runOptions(req, res);
  try {
    const allScopes = await listWorkflowsAllScopes(options);
    const availableScopes = availableScopesForId(allScopes, id);
    if (availableScopes.length === 0) {
      jsonError(res, 404, `Workflow "${id}" not found`);
      return;
    }
    const effectiveScope = effectiveScopeForId(allScopes, id);
    if (!effectiveScope) {
      jsonError(res, 404, `Workflow "${id}" not found`);
      return;
    }
    const scope = scopeQuery ?? effectiveScope;
    if (!availableScopes.some((entry) => entry.scope === scope)) {
      jsonError(res, 404, `Workflow "${id}" not found in ${scope} scope`);
      return;
    }
    if (scope === 'bundled') {
      jsonError(res, 403, 'Bundled workflows are immutable; use Customize to create a project copy');
      return;
    }
    const targetPath = await workflowPath(id, scope, options);
    const currentRaw = await fs.readFile(targetPath, 'utf8');
    const currentSha256 = createHash('sha256').update(currentRaw, 'utf8').digest('hex');
    if (currentSha256 !== clientSha256) {
      jsonError(res, 409, 'The file changed since it was loaded; reload before saving');
      return;
    }

    let content: string;
    if (typeof body['raw'] === 'string') {
      content = body['raw'];
    } else if (body['model'] && typeof body['model'] === 'object') {
      const currentParsed = parseWorkflowFrontmatter(currentRaw);
      const currentBody = currentParsed.ok ? currentParsed.model.body : '\n';
      try {
        const model = modelFromWire(body['model'] as Record<string, unknown>, currentRaw, currentBody);
        const localIssues = validateWorkflowModel(model);
        if (localIssues.length > 0) {
          res.status(422).json({ error: 'Workflow failed validation', diagnostics: formatValidationIssues(localIssues) });
          return;
        }
        content = emitWorkflowFrontmatter(model);
      } catch (error: unknown) {
        jsonError(res, 400, error instanceof WorkflowFrontmatterError ? error.message : 'Invalid workflow model');
        return;
      }
    } else {
      jsonError(res, 400, 'Request must include either "raw" or "model"');
      return;
    }

    const result = await writeValidated(targetPath, content, options);
    if (!result.ok) {
      res.status(422).json({ error: 'Workflow failed validation', diagnostics: result.diagnostics });
      return;
    }
    const sha256 = createHash('sha256').update(content, 'utf8').digest('hex');
    res.json({ sha256 });
  } catch (error: unknown) {
    handleCliError(res, error, `Workflow "${id}" not found`);
  }
}

async function handlePatchWorkflowRouting(req: Request, res: Response): Promise<void> {
  const id = String(req.params['id'] ?? '');
  if (!isValidWorkflowId(id)) {
    jsonError(res, 400, 'Invalid workflow id');
    return;
  }
  const scopeQuery = parseWorkflowScopeQuery(req.query['scope']);
  if (scopeQuery !== 'project' && scopeQuery !== 'global') {
    jsonError(res, 400, 'scope must be "project" or "global"');
    return;
  }
  const body = (req.body ?? {}) as Record<string, unknown>;
  const clientSha256 = typeof body['sha256'] === 'string' ? body['sha256'] : '';
  if (!clientSha256) {
    jsonError(res, 400, 'sha256 of the loaded file is required');
    return;
  }

  const patch: WorkflowRoutingPatch = {
    sha256: clientSha256,
    ...(body['defaults'] === null ? { defaults: null } : {}),
  };
  if (body['defaults'] !== undefined && typeof body['defaults'] === 'object' && body['defaults'] !== null) {
    const d = body['defaults'] as Record<string, unknown>;
    (patch as { defaults?: WorkflowRoutingPatch['defaults'] }).defaults = {
      runtime: d['runtime'] === null ? null : typeof d['runtime'] === 'string' ? d['runtime'] : undefined,
      model: d['model'] === null ? null : typeof d['model'] === 'string' ? d['model'] : undefined,
      clear: d['clear'] === true,
    };
  }
  if (body['stages'] !== undefined && typeof body['stages'] === 'object' && body['stages'] !== null && !Array.isArray(body['stages'])) {
    const stages: Record<string, { runtime?: string | null; model?: string | null; clear?: boolean } | null> = {};
    for (const [stageId, value] of Object.entries(body['stages'] as Record<string, unknown>)) {
      if (!isValidWorkflowId(stageId)) {
        jsonError(res, 400, `Invalid stage id: ${stageId}`);
        return;
      }
      if (value === null) {
        stages[stageId] = null;
        continue;
      }
      if (typeof value !== 'object') {
        jsonError(res, 400, `Invalid stage patch for ${stageId}`);
        return;
      }
      const s = value as Record<string, unknown>;
      stages[stageId] = {
        runtime: s['runtime'] === null ? null : typeof s['runtime'] === 'string' ? s['runtime'] : undefined,
        model: s['model'] === null ? null : typeof s['model'] === 'string' ? s['model'] : undefined,
        clear: s['clear'] === true,
      };
    }
    (patch as { stages?: WorkflowRoutingPatch['stages'] }).stages = stages;
  }

  const options = runOptions(req, res);
  try {
    const allScopes = await listWorkflowsAllScopes(options);
    const availableScopes = availableScopesForId(allScopes, id);
    if (!availableScopes.some((entry) => entry.scope === scopeQuery)) {
      jsonError(res, 404, `Workflow "${id}" not found in ${scopeQuery} scope`);
      return;
    }
    const newSha256 = await setWorkflowRouting(id, scopeQuery, patch, options);
    res.json({ scope: scopeQuery, sha256: newSha256 });
  } catch (error: unknown) {
    if (error instanceof RalphCliError) {
      const msg = error.stderr || error.message;
      if (msg.includes('sha256 conflict') || msg.includes('changed since load')) {
        jsonError(res, 409, 'The file changed since it was loaded; reload before saving');
        return;
      }
      if (msg.includes('does not accept runtime') || msg.includes('immutable')) {
        jsonError(res, 400, msg.trim());
        return;
      }
    }
    handleCliError(res, error, `Workflow "${id}" not found`);
  }
}

function parseCustomizeTargetScope(value: unknown): 'project' | 'global' | 'bundled' | undefined {
  if (value === 'project' || value === 'global' || value === 'bundled') {
    return value;
  }
  return undefined;
}

function parseCustomizeSourceScope(value: unknown): WorkflowScope | undefined {
  if (value === 'bundled' || value === 'global') {
    return value;
  }
  return undefined;
}

function defaultCustomizeSourceScope(
  targetScope: 'project' | 'global',
  availableScopes: readonly WorkflowScopeEntry[],
  effectiveScope: string,
): WorkflowScope | undefined {
  const hasScope = (scope: WorkflowScope) => availableScopes.some((entry) => entry.scope === scope);
  if (targetScope === 'global') {
    return hasScope('bundled') ? 'bundled' : undefined;
  }
  if (effectiveScope === 'global' && hasScope('global')) {
    return 'global';
  }
  if (effectiveScope === 'bundled' && hasScope('bundled')) {
    return 'bundled';
  }
  if (hasScope('global')) {
    return 'global';
  }
  if (hasScope('bundled')) {
    return 'bundled';
  }
  return undefined;
}

async function handleCustomizeWorkflow(req: Request, res: Response): Promise<void> {
  const id = String(req.params['id'] ?? '');
  if (!isValidWorkflowId(id)) {
    jsonError(res, 400, 'Invalid workflow id');
    return;
  }
  const body = (req.body ?? {}) as Record<string, unknown>;
  const targetScope =
    parseCustomizeTargetScope(body['targetScope']) ??
    (body['targetScope'] === undefined ? 'project' : undefined);
  if (!targetScope) {
    jsonError(res, 400, 'targetScope must be "project" or "global"');
    return;
  }
  if (targetScope === 'bundled') {
    jsonError(res, 403, 'Bundled workflows are immutable');
    return;
  }
  const explicitSource = body['sourceScope'] !== undefined ? parseCustomizeSourceScope(body['sourceScope']) : undefined;
  if (body['sourceScope'] !== undefined && explicitSource === undefined) {
    jsonError(res, 400, 'sourceScope must be "bundled" or "global"');
    return;
  }

  const options = runOptions(req, res);
  const targetPath = workflowFilePath(scopeDir(targetScope, workflowWorkspace(req, res)), id);
  try {
    if (existsSync(targetPath)) {
      const existing = await fs.readFile(targetPath, 'utf8');
      res.status(200).json({ scope: targetScope, sha256: sha256Hex(existing), created: false });
      return;
    }

    const allScopes = await listWorkflowsAllScopes(options);
    const availableScopes = availableScopesForId(allScopes, id);
    if (availableScopes.length === 0) {
      jsonError(res, 404, `Workflow "${id}" not found`);
      return;
    }
    const effectiveScope = effectiveScopeForId(allScopes, id);
    const sourceScope = explicitSource ?? defaultCustomizeSourceScope(targetScope, availableScopes, effectiveScope ?? '');
    if (!sourceScope) {
      jsonError(res, 404, `No source definition available to customize workflow "${id}"`);
      return;
    }
    if (!availableScopes.some((entry) => entry.scope === sourceScope)) {
      jsonError(res, 404, `Workflow "${id}" not found in ${sourceScope} scope`);
      return;
    }

    const raw = await showWorkflow(id, sourceScope, options);
    const result = await writeValidatedCreate(targetPath, raw, options);
    if (!result.ok) {
      res.status(422).json({ error: 'Workflow failed validation', diagnostics: result.diagnostics });
      return;
    }
    if (!result.created) {
      res.status(200).json({ scope: targetScope, sha256: result.sha256, created: false });
      return;
    }
    res.status(201).json({ scope: targetScope, sha256: result.sha256, created: true });
  } catch (error: unknown) {
    handleCliError(res, error, `Workflow "${id}" not found`);
  }
}

async function handleDeleteWorkflow(req: Request, res: Response): Promise<void> {
  const id = String(req.params['id'] ?? '');
  if (!isValidWorkflowId(id)) {
    jsonError(res, 400, 'Invalid workflow id');
    return;
  }
  const scope = typeof req.query['scope'] === 'string' ? req.query['scope'] : '';
  if (!isWritableScope(scope)) {
    jsonError(res, 400, 'scope query parameter must be "project" or "global"');
    return;
  }
  const targetPath = workflowFilePath(scopeDir(scope, workflowWorkspace(req, res)), id);
  if (!existsSync(targetPath)) {
    jsonError(res, 404, `Workflow "${id}" not found in ${scope} scope`);
    return;
  }
  await fs.unlink(targetPath);
  res.status(204).end();
}

export const START_RUN_ID_POLL_INTERVAL_MS = 150;

export function startRunIdTimeoutMs(): number {
  return Number(process.env['RALPH_DASHBOARD_START_RUN_ID_TIMEOUT_MS'] ?? 10_000);
}
const RESPOND_DECISIONS = new Set(['approve', 'request-changes', 'cancel', 'answer']);

/** Polls the run's log file for the `Run: <id>` line `ralph workflow start` prints right after dispatch, well before the (potentially long) supervised wait completes. */
export async function pollForRunId(logPath: string, timeoutMs: number): Promise<string | null> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const content = await fs.readFile(logPath, 'utf8');
      const match = /^Run: (\S+)/m.exec(content);
      if (match?.[1]) {
        return match[1];
      }
    } catch {
      // Log file not written yet.
    }
    if (Date.now() >= deadline) {
      return null;
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, START_RUN_ID_POLL_INTERVAL_MS));
  }
}

async function handleStartWorkflow(req: Request, res: Response): Promise<void> {
  const id = String(req.params['id'] ?? '');
  if (!isValidWorkflowId(id)) {
    jsonError(res, 400, 'Invalid workflow id');
    return;
  }
  const body = (req.body ?? {}) as Record<string, unknown>;
  const task = typeof body['task'] === 'string' ? body['task'].trim() : '';
  if (!task) {
    jsonError(res, 400, 'task is required');
    return;
  }
  const runtime = typeof body['runtime'] === 'string' ? body['runtime'] : undefined;
  const model = typeof body['model'] === 'string' ? body['model'] : undefined;
  if (runtime !== undefined && !RUNTIME_PATTERN.test(runtime)) {
    jsonError(res, 400, 'Invalid runtime');
    return;
  }

  const context = workflowWorkspace(req, res);
  const logDir = join(context.workspaceRoot, 'artifacts', 'dashboard-runs');
  await fs.mkdir(logDir, { recursive: true });
  const logPath = join(logDir, `${id}-${Date.now()}-${randomBytes(4).toString('hex')}.log`);

  try {
    startWorkflowDetached({ id, task, runtime, model }, logPath, runOptions(req, res));
  } catch (error: unknown) {
    handleCliError(res, error, `Workflow "${id}" not found`);
    return;
  }

  const runId = await pollForRunId(logPath, startRunIdTimeoutMs());
  if (!runId) {
    const tail = await fs.readFile(logPath, 'utf8').catch(() => '');
    res.status(202).json({ status: 'pending', logPath, tail: tail.slice(-2000) });
    return;
  }
  res.status(202).json({ runId, logPath });
}

async function handleCancelRun(req: Request, res: Response): Promise<void> {
  const runId = String(req.params['runId'] ?? '');
  if (!isValidRunId(runId)) {
    jsonError(res, 400, 'Invalid run id');
    return;
  }
  try {
    await cancelRun(runId, runOptions(req, res));
    res.json({ ok: true });
  } catch (error: unknown) {
    handleCliError(res, error, `Run "${runId}" not found`);
  }
}

async function handleResumeRun(req: Request, res: Response): Promise<void> {
  const runId = String(req.params['runId'] ?? '');
  if (!isValidRunId(runId)) {
    jsonError(res, 400, 'Invalid run id');
    return;
  }
  try {
    await resumeRun(runId, runOptions(req, res));
    res.json({ ok: true });
  } catch (error: unknown) {
    handleCliError(res, error, `Run "${runId}" not found`);
  }
}

async function handleResetRun(req: Request, res: Response): Promise<void> {
  const runId = String(req.params['runId'] ?? '');
  if (!isValidRunId(runId)) {
    jsonError(res, 400, 'Invalid run id');
    return;
  }
  const body = (req.body ?? {}) as Record<string, unknown>;
  const stage = typeof body['stage'] === 'string' ? body['stage'] : undefined;
  const all = body['all'] === true;
  if (!stage && !all) {
    jsonError(res, 400, 'reset requires "stage" or "all": true');
    return;
  }
  if (stage && !isValidWorkflowId(stage)) {
    jsonError(res, 400, 'Invalid stage id');
    return;
  }
  try {
    await resetRun({ runId, stage, all }, runOptions(req, res));
    res.json({ ok: true });
  } catch (error: unknown) {
    handleCliError(res, error, `Run "${runId}" not found`);
  }
}

async function handleListRunActions(req: Request, res: Response): Promise<void> {
  const runId = String(req.params['runId'] ?? '');
  if (!isValidRunId(runId)) {
    jsonError(res, 400, 'Invalid run id');
    return;
  }
  try {
    res.json(await listActions(runId, runOptions(req, res)));
  } catch (error: unknown) {
    handleCliError(res, error, `Run "${runId}" not found`);
  }
}

async function handleRespondRunAction(req: Request, res: Response): Promise<void> {
  const runId = String(req.params['runId'] ?? '');
  if (!isValidRunId(runId)) {
    jsonError(res, 400, 'Invalid run id');
    return;
  }
  const body = (req.body ?? {}) as Record<string, unknown>;
  const requestId = typeof body['requestId'] === 'string' ? body['requestId'] : '';
  const decision = typeof body['decision'] === 'string' ? body['decision'] : '';
  if (!requestId || !RESPOND_DECISIONS.has(decision)) {
    jsonError(res, 400, 'requestId and a valid decision (approve, request-changes, cancel, answer) are required');
    return;
  }
  const message = typeof body['message'] === 'string' ? body['message'] : undefined;
  try {
    await respondAction(
      { runId, requestId, decision: decision as 'approve' | 'request-changes' | 'cancel' | 'answer', message },
      runOptions(req, res),
    );
    res.json({ ok: true });
  } catch (error: unknown) {
    handleCliError(res, error, `Run "${runId}" or request "${requestId}" not found`);
  }
}

export function registerWorkflowApi(app: Express): void {
  app.get('/api/workflows', workflowWorkspaceMiddleware, handleListWorkflows);
  app.get('/api/workflows/:id', workflowWorkspaceMiddleware, handleGetWorkflow);
  app.get('/api/workflows/:id/runs', workflowWorkspaceMiddleware, handleWorkflowRuns);
  app.get('/api/workflow-runs', workflowWorkspaceMiddleware, handleWorkflowRunsList);
  app.get('/api/workflow-runs/:runId', workflowWorkspaceMiddleware, handleWorkflowRunDetail);
  app.get('/api/workflow-runs/:runId/stages/:stageId/logs', workflowWorkspaceMiddleware, handleWorkflowStageLogs);
  app.get('/api/workflow-runtimes', handleWorkflowRuntimes);
  app.get('/api/workflow-runtimes/:runtime/models', workflowWorkspaceMiddleware, handleWorkflowRuntimeModels);

  app.post('/api/workflows', workflowWorkspaceMiddleware, writeGuard, handleCreateWorkflow);
  app.put('/api/workflows/:id', workflowWorkspaceMiddleware, writeGuard, handleUpdateWorkflow);
  app.patch('/api/workflows/:id/routing', workflowWorkspaceMiddleware, writeGuard, handlePatchWorkflowRouting);
  app.post('/api/workflows/:id/customize', workflowWorkspaceMiddleware, writeGuard, handleCustomizeWorkflow);
  app.delete('/api/workflows/:id', workflowWorkspaceMiddleware, writeGuard, handleDeleteWorkflow);

  app.post('/api/workflows/:id/start', workflowWorkspaceMiddleware, writeGuard, handleStartWorkflow);
  app.post('/api/workflow-runs/:runId/cancel', workflowWorkspaceMiddleware, writeGuard, handleCancelRun);
  app.post('/api/workflow-runs/:runId/resume', workflowWorkspaceMiddleware, writeGuard, handleResumeRun);
  app.post('/api/workflow-runs/:runId/reset', workflowWorkspaceMiddleware, writeGuard, handleResetRun);
  app.get('/api/workflow-runs/:runId/actions', workflowWorkspaceMiddleware, handleListRunActions);
  app.post('/api/workflow-runs/:runId/actions/respond', workflowWorkspaceMiddleware, writeGuard, handleRespondRunAction);
}
