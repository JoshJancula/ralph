import { existsSync, realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { findDashboardRoots, type DashboardRoots } from '../paths';

export function resolveDashboardRootsForWorkspaceRoot(
  workspaceRootQuery: string | undefined,
  allowlist: ReadonlyArray<{ projectRoot: string; workspaceRoot: string }>,
): DashboardRoots | null {
  const trimmed = typeof workspaceRootQuery === 'string' ? workspaceRootQuery.trim() : '';
  if (!trimmed) {
    return findDashboardRoots();
  }

  const target = resolve(trimmed);
  let canonicalTarget = target;
  try {
    canonicalTarget = existsSync(target) ? realpathSync(target) : target;
  } catch {
    canonicalTarget = target;
  }

  for (const entry of allowlist) {
    const entryWs = resolve(entry.workspaceRoot);
    let canonicalEntry = entryWs;
    try {
      canonicalEntry = existsSync(entryWs) ? realpathSync(entryWs) : entryWs;
    } catch {
      canonicalEntry = entryWs;
    }
    if (canonicalEntry === canonicalTarget || entryWs === target) {
      return {
        projectRoot: resolve(entry.projectRoot),
        workspaceRoot: entryWs,
      };
    }
  }

  return null;
}
