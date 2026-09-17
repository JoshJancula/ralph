import { describe, expect, it } from 'vitest';
import {
  catalogBadgeLabels,
  matchesWorkflowCatalogSearch,
  workflowCatalogSearchText,
} from './workflow-catalog.helpers';
import type { WorkflowListItem } from './workflow.types';

const ITEM: WorkflowListItem = {
  id: 'plan-delivery',
  scope: 'bundled',
  effectiveScope: 'bundled',
  overview: 'Execute supplied plan',
  editable: false,
  catalog: {
    purpose: 'Execute supplied plan',
    expectedOutcome: 'Independently verified delivery',
    mode: 'dependency',
    stageCount: 5,
    executableStageCount: 3,
    supervisorStageCount: 2,
    requiresSuppliedPlan: true,
    writes: true,
    hasHumanGates: false,
  },
};

describe('workflow-catalog.helpers', () => {
  it('matches search against catalog-derived supplied-plan and gates terms', () => {
    expect(matchesWorkflowCatalogSearch(ITEM, 'supplied plan')).toBe(true);
    expect(matchesWorkflowCatalogSearch(ITEM, 'human gates')).toBe(false);
    expect(workflowCatalogSearchText(ITEM)).toContain('requires plan');
  });

  it('builds badge labels from catalog meta', () => {
    expect(catalogBadgeLabels(ITEM.catalog)).toEqual([
      'dependency',
      '5 stages',
      'Requires supplied plan',
      'Writes',
    ]);
  });
});
