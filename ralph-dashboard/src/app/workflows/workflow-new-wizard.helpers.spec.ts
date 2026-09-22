import { describe, expect, it } from 'vitest';
import {
  BLANK_TEMPLATE_ID,
  applyHumanGatePreference,
  buildStageMap,
  buildTemplateCards,
  canAdvanceFromStep1,
  canAdvanceFromStep2,
  canCreate,
  collectDraftWarnings,
  createEmptyDraft,
  draftRequiresSuppliedPlan,
  buildPatternGroups,
  groupTemplateCardsByOutcome,
  isDraftDirty,
  suggestIdFromTemplate,
} from './workflow-new-wizard.helpers';
import type { WorkflowListItem, WorkflowStageModel } from './workflow.types';

const WORKFLOWS: WorkflowListItem[] = [
  {
    id: 'plan-delivery',
    scope: 'bundled',
    overview: 'Supplied plan',
    editable: false,
    catalog: {
      purpose: 'Supplied plan',
      expectedOutcome: 'Independently verified delivery',
      mode: 'dependency',
      stageCount: 5,
      executableStageCount: 3,
      supervisorStageCount: 2,
      requiresSuppliedPlan: true,
      writes: true,
      hasHumanGates: false,
    },
  },
  {
    id: 'investigation',
    scope: 'bundled',
    overview: 'Read-only study',
    editable: false,
    catalog: {
      purpose: 'Read-only study',
      expectedOutcome: 'Read-only findings (no publication)',
      mode: 'dependency',
      stageCount: 2,
      executableStageCount: 2,
      supervisorStageCount: 0,
      requiresSuppliedPlan: false,
      writes: false,
      hasHumanGates: false,
    },
  },
];

describe('workflow-new-wizard.helpers', () => {
  it('buildTemplateCards appends Blank as an advanced path', () => {
    const cards = buildTemplateCards(WORKFLOWS);
    expect(cards.some((c) => c.id === 'plan-delivery')).toBe(true);
    const blank = cards[cards.length - 1];
    expect(blank?.id).toBe(BLANK_TEMPLATE_ID);
    expect(blank?.isAdvanced).toBe(true);
    expect(blank?.isBlank).toBe(true);
  });

  it('buildPatternGroups prepends quick-start templates not already in the catalog', () => {
    const groups = buildPatternGroups(buildTemplateCards(WORKFLOWS), [
      {
        id: 'starter-only-template',
        category: 'Trade analysis',
        purpose: 'Pulse',
        outputs: 'Brief',
        safety: 'Analysis only',
        stageCount: 1,
      },
    ]);
    const quick = groups.find((g) => g.outcome === 'Quick-start templates');
    expect(quick?.cards.map((c) => c.id)).toEqual(['starter-only-template']);
    expect(quick?.cards[0]?.isInstallableStarter).toBe(true);

    const withCatalogDup = buildPatternGroups(buildTemplateCards(WORKFLOWS), [
      {
        id: 'plan-delivery',
        category: 'Software development',
        purpose: 'Dup',
        outputs: 'x',
        safety: 'y',
        stageCount: 1,
      },
    ]);
    expect(withCatalogDup.some((g) => g.outcome === 'Quick-start templates')).toBe(false);
  });

  it('groupTemplateCardsByOutcome groups human outcomes and isolates Advanced', () => {
    const groups = groupTemplateCardsByOutcome(buildTemplateCards(WORKFLOWS));
    expect(groups.some((g) => g.outcome === 'Independently verified delivery')).toBe(true);
    expect(groups.some((g) => g.outcome === 'Read-only findings (no publication)')).toBe(true);
    const advanced = groups.find((g) => g.outcome === 'Advanced');
    expect(advanced?.cards).toHaveLength(1);
    expect(advanced?.cards[0]?.isBlank).toBe(true);
  });

  it('draftRequiresSuppliedPlan honors catalog and planInput.required', () => {
    const cards = buildTemplateCards(WORKFLOWS);
    const draft = createEmptyDraft();
    draft.templateId = 'plan-delivery';
    expect(draftRequiresSuppliedPlan(draft, cards)).toBe(true);
    draft.templateId = 'investigation';
    expect(draftRequiresSuppliedPlan(draft, cards)).toBe(false);
    draft.planInput = { stage: 'implement', required: true };
    expect(draftRequiresSuppliedPlan(draft, cards)).toBe(true);
  });

  it('canAdvanceFromStep2 / canCreate enforce supplied-plan readiness', () => {
    const draft = createEmptyDraft();
    draft.templateId = 'plan-delivery';
    draft.id = 'my-plan-delivery';
    draft.step = 2;
    expect(canAdvanceFromStep2(draft, true)).toBe(false);
    draft.selectedPlanPath = 'plans/x.md';
    expect(canAdvanceFromStep2(draft, true)).toBe(true);
    draft.step = 4;
    expect(canCreate(draft, true)).toBe(true);
    draft.selectedPlanPath = null;
    expect(canCreate(draft, true)).toBe(false);
  });

  it('canAdvanceFromStep1 requires a template selection', () => {
    const draft = createEmptyDraft();
    expect(canAdvanceFromStep1(draft)).toBe(false);
    draft.templateId = BLANK_TEMPLATE_ID;
    expect(canAdvanceFromStep1(draft)).toBe(true);
  });

  it('buildStageMap and human-gate stripping', () => {
    const stages: WorkflowStageModel[] = [
      { id: 'a', kind: 'ordinary', dependsOn: [], produces: [], requires: [], unsupportedKeys: [] },
      {
        id: 'gate',
        kind: 'supervisor',
        type: 'approval',
        dependsOn: ['a'],
        changesTarget: 'a',
        unsupportedKeys: [],
      },
      { id: 'b', kind: 'ordinary', dependsOn: ['gate'], produces: [], requires: [], unsupportedKeys: [] },
    ];
    expect(buildStageMap(stages)).toHaveLength(3);
    const stripped = applyHumanGatePreference(stages, false);
    expect(stripped.map((s) => s.id)).toEqual(['a', 'b']);
    expect(stripped[1]?.dependsOn).toEqual([]);
  });

  it('collectDraftWarnings covers plan, blank, and unsupported keys', () => {
    const draft = createEmptyDraft();
    draft.templateId = BLANK_TEMPLATE_ID;
    draft.unsupportedKeys = ['legacy'];
    const warnings = collectDraftWarnings({
      draft,
      requiresPlan: true,
      templateHasHumanGates: false,
    });
    expect(warnings.some((w) => /supplied plan/.test(w))).toBe(true);
    expect(warnings.some((w) => /Blank workflow/.test(w))).toBe(true);
    expect(warnings.some((w) => /unsupported keys/.test(w))).toBe(true);
  });

  it('isDraftDirty and suggestIdFromTemplate', () => {
    expect(isDraftDirty(createEmptyDraft())).toBe(false);
    const draft = createEmptyDraft();
    draft.intent = 'ship feature';
    expect(isDraftDirty(draft)).toBe(true);
    expect(suggestIdFromTemplate('feature-delivery')).toBe('my-feature-delivery');
    expect(suggestIdFromTemplate(BLANK_TEMPLATE_ID)).toBe('');
  });
});
