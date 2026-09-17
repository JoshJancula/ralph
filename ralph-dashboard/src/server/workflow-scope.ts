import type { WorkflowListEntry, WorkflowScope } from './ralph-cli';

export const WORKFLOW_SCOPE_ORDER: readonly WorkflowScope[] = ['project', 'global', 'bundled'];

export interface WorkflowScopeEntry {
  readonly scope: WorkflowScope;
  readonly overview: string;
}

export function parseWorkflowScopeQuery(value: unknown): WorkflowScope | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  const trimmed = value.trim();
  if (trimmed === 'project' || trimmed === 'global' || trimmed === 'bundled') {
    return trimmed;
  }
  return undefined;
}

export function isWorkflowScope(value: string): value is WorkflowScope {
  return value === 'project' || value === 'global' || value === 'bundled';
}

/** Winner scope for an id from an all-scopes listing (project -> global -> bundled). */
export function effectiveScopeForId(rows: readonly WorkflowListEntry[], id: string): WorkflowScope | undefined {
  const scopes = new Set(rows.filter((row) => row.id === id).map((row) => row.scope as WorkflowScope));
  for (const scope of WORKFLOW_SCOPE_ORDER) {
    if (scopes.has(scope)) {
      return scope;
    }
  }
  return undefined;
}

export function availableScopesForId(rows: readonly WorkflowListEntry[], id: string): readonly WorkflowScopeEntry[] {
  const byScope = new Map<WorkflowScope, string>();
  for (const row of rows) {
    if (row.id !== id) {
      continue;
    }
    const scope = row.scope as WorkflowScope;
    if (!isWorkflowScope(scope)) {
      continue;
    }
    if (!byScope.has(scope)) {
      byScope.set(scope, row.overview);
    }
  }
  return WORKFLOW_SCOPE_ORDER.filter((scope) => byScope.has(scope)).map((scope) => ({
    scope,
    overview: byScope.get(scope) ?? '',
  }));
}

export function shadowedByScope(
  effectiveScope: WorkflowScope,
  requestedScope: WorkflowScope,
): { readonly scope: WorkflowScope } | undefined {
  if (requestedScope === effectiveScope) {
    return undefined;
  }
  const effectiveRank = WORKFLOW_SCOPE_ORDER.indexOf(effectiveScope);
  const requestedRank = WORKFLOW_SCOPE_ORDER.indexOf(requestedScope);
  if (effectiveRank < 0 || requestedRank < 0 || effectiveRank >= requestedRank) {
    return undefined;
  }
  return { scope: effectiveScope };
}
