/**
 * Dashboard HTTP surface for Ralph safety (killswitch) config.
 * Project scope only: `<state-root>/killswitch.json`. Writes go through
 * writeGuard, rules-only merge, temp+validate+rename (same shape as workflow
 * writeValidated), and never flip enabled/dry_run from the browser.
 */
import { randomBytes } from 'node:crypto';
import { existsSync, promises as fs } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import type { Express, Request, RequestHandler, Response } from 'express';
import { findDashboardRoots, type DashboardRoots, resolveRalphInstallRoot } from '../paths';
import { getMergedWorkspaceAllowlist } from './dashboard-api';
import { resolveDashboardRootsForWorkspaceRoot } from './dashboard-workspace-resolve';
import {
  RalphCliError,
  safetyCheckCommand,
  safetyStatus,
  safetyValidateFile,
  type RunOptions,
} from './ralph-cli';
import { mergeSafetyConfig, SafetyConfigError, sha256Hex } from './safety-config';
import { writeGuard } from './write-guard';

function jsonError(res: Response, status: number, message: string): void {
  res.status(status).json({ error: message });
}

type SafetyRequest = Request & { ralphSafetyWorkspace?: DashboardRoots };

function attachSafetyContext(req: Request, res: Response, roots: DashboardRoots): void {
  res.locals['ralphSafetyWorkspace'] = roots;
  (req as SafetyRequest).ralphSafetyWorkspace = roots;
}

function safetyWorkspace(req: Request, res: Response): DashboardRoots {
  const context =
    (res.locals as { ralphSafetyWorkspace?: DashboardRoots }).ralphSafetyWorkspace ??
    (req as SafetyRequest).ralphSafetyWorkspace;
  if (!context) {
    throw new Error('safety workspace context missing');
  }
  return context;
}

function runOptions(req: Request, res: Response): RunOptions {
  const context = safetyWorkspace(req, res);
  return {
    cwd: context.projectRoot,
    projectRoot: context.projectRoot,
    workspaceRoot: context.workspaceRoot,
  };
}

const safetyWorkspaceMiddleware: RequestHandler = async (req, res, next) => {
  try {
    const query = typeof req.query['workspaceRoot'] === 'string' ? req.query['workspaceRoot'].trim() : '';
    const allowlist = await getMergedWorkspaceAllowlist();
    const roots = query ? resolveDashboardRootsForWorkspaceRoot(query, allowlist) : findDashboardRoots();
    if (roots === null) {
      jsonError(res, 400, 'invalid workspaceRoot');
      return;
    }
    attachSafetyContext(req, res, roots);
    next();
  } catch (error: unknown) {
    jsonError(res, 500, error instanceof Error ? error.message : 'workspace resolution failed');
  }
};

function projectKillswitchPath(context: DashboardRoots): string {
  return join(context.workspaceRoot, 'killswitch.json');
}

function dumpsNormalized(config: Record<string, unknown>): string {
  return `${JSON.stringify(config, null, 2)}\n`;
}

function bundleKillswitchCandidates(): string[] {
  const out: string[] = [];
  const installRoot = resolveRalphInstallRoot();
  if (installRoot) {
    out.push(join(installRoot, 'bundle', '.ralph', 'killswitch.json'));
  }
  // Repo-root checkout when the dashboard is run from ralph-dashboard/ or the monorepo root.
  out.push(join(process.cwd(), 'bundle', '.ralph', 'killswitch.json'));
  out.push(join(process.cwd(), '..', 'bundle', '.ralph', 'killswitch.json'));
  return out;
}

async function loadBundleSeedRaw(): Promise<string> {
  for (const candidate of bundleKillswitchCandidates()) {
    if (!existsSync(candidate)) {
      continue;
    }
    return fs.readFile(candidate, 'utf8');
  }
  throw new Error('bundle default killswitch.json not found');
}

async function loadProjectOrSeed(context: DashboardRoots): Promise<{
  readonly raw: string;
  readonly config: Record<string, unknown>;
  readonly exists: boolean;
  readonly path: string;
}> {
  const path = projectKillswitchPath(context);
  if (existsSync(path)) {
    const raw = await fs.readFile(path, 'utf8');
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('project killswitch.json must be a JSON object');
    }
    return { raw, config: parsed as Record<string, unknown>, exists: true, path };
  }
  const raw = await loadBundleSeedRaw();
  const parsed = JSON.parse(raw) as unknown;
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('bundle killswitch.json must be a JSON object');
  }
  return { raw, config: parsed as Record<string, unknown>, exists: false, path };
}

/**
 * Writes `content` beside `targetPath`, validates with `ralph safety validate --file`,
 * renames into place only on success, and always removes the temp file. On failure
 * `targetPath` is left byte-identical to before the call.
 */
async function writeValidatedSafety(
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
      await safetyValidateFile(tmpPath, options);
    } catch (error: unknown) {
      const diagnostics =
        error instanceof RalphCliError
          ? error.stderr || error.message
          : error instanceof Error
            ? error.message
            : 'validation failed';
      return { ok: false, diagnostics };
    }
    await fs.rename(tmpPath, targetPath);
    return { ok: true };
  } finally {
    await fs.unlink(tmpPath).catch(() => undefined);
  }
}

function handleCliError(res: Response, error: unknown): void {
  if (error instanceof RalphCliError) {
    jsonError(res, 502, error.stderr || error.message);
    return;
  }
  jsonError(res, 502, error instanceof Error ? error.message : 'ralph command failed');
}

async function handleSafetyStatus(req: Request, res: Response): Promise<void> {
  try {
    const status = await safetyStatus(runOptions(req, res));
    res.json(status);
  } catch (error: unknown) {
    handleCliError(res, error);
  }
}

async function handleGetSafetyConfig(req: Request, res: Response): Promise<void> {
  try {
    const context = safetyWorkspace(req, res);
    const loaded = await loadProjectOrSeed(context);
    res.json({
      config: loaded.config,
      sha256: sha256Hex(loaded.raw),
      exists: loaded.exists,
      path: loaded.path,
    });
  } catch (error: unknown) {
    jsonError(res, 500, error instanceof Error ? error.message : 'failed to load safety config');
  }
}

async function handleSafetyCheck(req: Request, res: Response): Promise<void> {
  const body = (req.body ?? {}) as Record<string, unknown>;
  const command = typeof body['command'] === 'string' ? body['command'] : '';
  if (!command) {
    jsonError(res, 400, 'command is required');
    return;
  }
  try {
    const result = await safetyCheckCommand(command, runOptions(req, res));
    res.json(result);
  } catch (error: unknown) {
    handleCliError(res, error);
  }
}

async function handlePutSafetyConfig(req: Request, res: Response): Promise<void> {
  const body = (req.body ?? {}) as Record<string, unknown>;
  const clientSha256 = typeof body['sha256'] === 'string' ? body['sha256'] : '';
  if (!clientSha256) {
    jsonError(res, 400, 'sha256 of the loaded file is required');
    return;
  }

  const options = runOptions(req, res);
  const context = safetyWorkspace(req, res);
  try {
    const loaded = await loadProjectOrSeed(context);
    const currentSha256 = sha256Hex(loaded.raw);
    if (currentSha256 !== clientSha256) {
      jsonError(res, 409, 'The file changed since it was loaded; reload before saving');
      return;
    }

    let merged: Record<string, unknown>;
    try {
      merged = mergeSafetyConfig(loaded.config, body);
    } catch (error: unknown) {
      if (error instanceof SafetyConfigError) {
        jsonError(res, 400, error.message);
        return;
      }
      throw error;
    }

    const content = dumpsNormalized(merged);
    const result = await writeValidatedSafety(loaded.path, content, options);
    if (!result.ok) {
      res.status(422).json({ error: 'Safety config failed validation', diagnostics: result.diagnostics });
      return;
    }
    res.json({ sha256: sha256Hex(content), exists: true, path: loaded.path });
  } catch (error: unknown) {
    jsonError(res, 500, error instanceof Error ? error.message : 'update safety config failed');
  }
}

export function registerSafetyApi(app: Express): void {
  app.get('/api/safety/status', safetyWorkspaceMiddleware, (req, res) => void handleSafetyStatus(req, res));
  app.get('/api/safety/config', safetyWorkspaceMiddleware, (req, res) => void handleGetSafetyConfig(req, res));
  app.post('/api/safety/check', safetyWorkspaceMiddleware, writeGuard, (req, res) => void handleSafetyCheck(req, res));
  app.put('/api/safety/config', safetyWorkspaceMiddleware, writeGuard, (req, res) => void handlePutSafetyConfig(req, res));
}
