/**
 * Read-through cache for expensive dashboard read endpoints.
 *
 * `GET /api/workflows` and `GET /api/workflows/:id` resolve their data by
 * spawning the Ralph CLI: two `workflow list` invocations plus one
 * `workflow show` per workflow for the list, and show + two inspect passes for
 * the detail. Each spawn costs roughly 0.2-1.9s, so an uncached list request
 * measured about 3s wall clock and peaked at 31 concurrent child processes.
 *
 * The CLI stays the single source of truth for scope resolution (precedence,
 * symlink de-duplication, ordering). This module only decides whether the
 * previous answer is still valid, using a cheap filesystem fingerprint of the
 * three scope directories. Because the fingerprint covers file mtime and size,
 * every mutation (create, update, routing patch, customize, delete) changes it
 * implicitly and the next read recomputes -- there is no invalidation to call
 * from the write handlers.
 */

import { readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { resolveRalphInstallRoot } from '../paths';

const WORKFLOW_FILE_SUFFIX = '.workflow.md';

/** Entries are small; the bound just stops unbounded growth across workspaces. */
const CACHE_MAX_ENTRIES = 256;

const cache = new Map<string, { readonly fingerprint: string; readonly createdAt: number; readonly value: unknown }>();

function ralphHome(): string {
  return resolveRalphInstallRoot() ?? join(homedir(), '.ralph');
}

/**
 * The three directories the CLI scans, in precedence order. Mirrors
 * `workflow_resource_{project,global,bundled}_dir` in
 * bash-lib/workflow/workflow-resource.sh.
 */
export function workflowScopeDirs(workspaceRoot: string): readonly string[] {
  const home = ralphHome();
  return [
    join(workspaceRoot, 'workflows'),
    join(home, 'workflows'),
    join(home, 'bundle', '.ralph', 'workflows'),
  ];
}

/** Name, mtime, and size of every workflow file in `dir`. Missing dir yields a stable empty marker. */
function dirFingerprint(dir: string): string {
  let names: string[];
  try {
    names = readdirSync(dir)
      .filter((name) => name.endsWith(WORKFLOW_FILE_SUFFIX))
      .sort();
  } catch {
    return `${dir}[]`;
  }
  const parts = names.map((name) => {
    try {
      const stats = statSync(join(dir, name));
      return `${name}:${stats.mtimeMs}:${stats.size}`;
    } catch {
      return `${name}:missing`;
    }
  });
  return `${dir}[${parts.join(',')}]`;
}

/**
 * Cheap change-detector for a workspace's workflow definitions. Costs a
 * readdir plus one stat per file (about 17 files here, sub-millisecond)
 * against the multi-second CLI spawns it guards.
 *
 * The resolved `ralph` binary is part of the key so tests that swap in a
 * different stub executable never read another test's cached answer.
 */
export function workflowReadFingerprint(workspaceRoot: string): string {
  const bin = process.env['RALPH_DASHBOARD_RALPH_BIN']?.trim() ?? '';
  let binPart = bin;
  if (bin) {
    try {
      const stats = statSync(bin);
      binPart = `${bin}:${stats.mtimeMs}:${stats.size}`;
    } catch {
      // Unresolvable stub path still participates by path alone.
    }
  }
  return [binPart, ...workflowScopeDirs(workspaceRoot).map(dirFingerprint)].join('|');
}

/**
 * Returns the cached value for `key` when `fingerprint` still matches and the
 * optional TTL has not elapsed, otherwise runs `producer` and stores its
 * result. A throwing producer is not cached, so transient CLI failures do not
 * become sticky.
 */
export async function cachedWorkflowRead<T>(
  key: string,
  fingerprint: string,
  producer: () => Promise<T>,
  options: { readonly ttlMs?: number } = {},
): Promise<T> {
  const hit = cache.get(key);
  const ttlMs = options.ttlMs ?? Number.POSITIVE_INFINITY;
  if (hit && hit.fingerprint === fingerprint && Date.now() - hit.createdAt < ttlMs) {
    return hit.value as T;
  }
  const value = await producer();
  if (cache.size >= CACHE_MAX_ENTRIES) {
    cache.clear();
  }
  cache.set(key, { fingerprint, createdAt: Date.now(), value });
  return value;
}

export function clearWorkflowReadCache(): void {
  cache.clear();
}
