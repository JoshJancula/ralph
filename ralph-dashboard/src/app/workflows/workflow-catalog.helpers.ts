import type { WorkflowCatalogMeta, WorkflowListItem, WorkflowScope } from './workflow.types';

const SCOPE_ORDER: readonly WorkflowScope[] = ['project', 'global', 'bundled'];

/** Search haystack for catalog filtering — uses server-derived catalog fields only. */
export function workflowCatalogSearchText(item: WorkflowListItem): string {
  const catalog = item.catalog;
  const parts = [
    item.id,
    item.overview,
    item.effectiveScope ?? item.scope,
    catalog?.purpose,
    catalog?.expectedOutcome,
    catalog?.mode,
    catalog?.requiresSuppliedPlan ? 'supplied plan requires plan' : '',
    catalog?.writes ? 'writes mutation' : 'read-only',
    catalog?.hasHumanGates ? 'human gates approval' : '',
    item.inheritsFrom?.explanation,
  ];
  return parts.filter(Boolean).join(' ').toLowerCase();
}

export function matchesWorkflowCatalogSearch(item: WorkflowListItem, query: string): boolean {
  const trimmed = query.trim().toLowerCase();
  if (!trimmed) {
    return true;
  }
  return workflowCatalogSearchText(item).includes(trimmed);
}

export function groupWorkflowsByEffectiveScope(
  workflows: readonly WorkflowListItem[],
): Map<WorkflowScope, WorkflowListItem[]> {
  const map = new Map<WorkflowScope, WorkflowListItem[]>();
  for (const scope of SCOPE_ORDER) {
    map.set(scope, []);
  }
  for (const workflow of workflows) {
    const bucket = workflow.effectiveScope ?? workflow.scope;
    map.get(bucket)?.push(workflow);
  }
  return map;
}

export function catalogBadgeLabels(catalog: WorkflowCatalogMeta | undefined): readonly string[] {
  if (!catalog) {
    return [];
  }
  const labels: string[] = [];
  if (catalog.mode) {
    labels.push(catalog.mode);
  }
  labels.push(`${catalog.stageCount} stages`);
  if (catalog.requiresSuppliedPlan) {
    labels.push('Requires supplied plan');
  }
  labels.push(catalog.writes ? 'Writes' : 'Read-only');
  if (catalog.hasHumanGates) {
    labels.push('Human gates');
  }
  return labels;
}
