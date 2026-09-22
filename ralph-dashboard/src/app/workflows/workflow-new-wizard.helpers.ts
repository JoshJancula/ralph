/**
 * Pure helpers for the New workflow guided wizard.
 * Draft state stays local until explicit Create; no filesystem writes here.
 */
import type {
  PathEntry,
  PlanInputModel,
  VerificationProfileModel,
  WorkflowListItem,
  WorkflowMode,
  WorkflowStageModel,
  WritableWorkflowScope,
} from './workflow.types';

export type WizardStep = 1 | 2 | 3 | 4;

/** Sentinel id for the explicit advanced blank path (not a catalog workflow). */
export const BLANK_TEMPLATE_ID = '__blank__';

export interface DashboardStarterTemplate {
  readonly id: string;
  readonly category: string;
  readonly purpose: string;
  readonly outputs: string;
  readonly safety: string;
  readonly stageCount: number;
}

export interface WizardTemplateCard {
  readonly id: string;
  readonly title: string;
  readonly purpose: string;
  readonly expectedOutcome: string;
  readonly requiresSuppliedPlan: boolean;
  readonly hasHumanGates: boolean;
  readonly stageCount: number;
  readonly mode: string | null;
  readonly isBlank: boolean;
  readonly isAdvanced: boolean;
  /** Installs a project workflow copy on first pick (dashboard template API). */
  readonly isInstallableStarter: boolean;
}

export interface StageMapEntry {
  readonly id: string;
  readonly kind: string;
  readonly type?: string;
  readonly dependsOn: readonly string[];
}

export interface WizardDraft {
  step: WizardStep;
  templateId: string | null;
  intent: string;
  id: string;
  scope: WritableWorkflowScope;
  name: string;
  overview: string;
  mode: WorkflowMode;
  defaultsRuntime: string;
  defaultsModel: string;
  maxParallel: number;
  maxReworkIterations: number;
  /** When false, approval/input supervisor stages are stripped from the local draft. */
  preferHumanGates: boolean;
  stages: WorkflowStageModel[];
  planInput?: PlanInputModel;
  publishMode?: string;
  verificationProfiles?: VerificationProfileModel[];
  selectedPlanPath: string | null;
  selectedPlanName: string | null;
  taskDescription: string;
  warnings: string[];
  unsupportedKeys: string[];
  templateLoadError: string | null;
}

const HUMAN_GATE_TYPES = new Set(['approval', 'input']);

export function createEmptyDraft(): WizardDraft {
  return {
    step: 1,
    templateId: null,
    intent: '',
    id: '',
    scope: 'project',
    name: '',
    overview: '',
    mode: 'dependency',
    defaultsRuntime: '',
    defaultsModel: '',
    maxParallel: 1,
    maxReworkIterations: 1,
    preferHumanGates: true,
    stages: [],
    selectedPlanPath: null,
    selectedPlanName: null,
    taskDescription: '',
    warnings: [],
    unsupportedKeys: [],
    templateLoadError: null,
  };
}

/** Catalog cards plus an explicit Blank advanced card at the end. */
export function buildTemplateCards(workflows: readonly WorkflowListItem[]): WizardTemplateCard[] {
  const cards: WizardTemplateCard[] = workflows.map((item) => {
    const catalog = item.catalog;
    return {
      id: item.id,
      title: item.id,
      purpose: catalog?.purpose || item.overview || 'No overview',
      expectedOutcome: catalog?.expectedOutcome || 'Completed stage outputs',
      requiresSuppliedPlan: catalog?.requiresSuppliedPlan === true,
      hasHumanGates: catalog?.hasHumanGates === true,
      stageCount: catalog?.stageCount ?? 0,
      mode: catalog?.mode ?? null,
      isBlank: false,
      isAdvanced: false,
      isInstallableStarter: false,
    };
  });
  cards.sort((a, b) => {
    const outcomeCmp = a.expectedOutcome.localeCompare(b.expectedOutcome);
    if (outcomeCmp !== 0) {
      return outcomeCmp;
    }
    return a.id.localeCompare(b.id);
  });
  cards.push({
    id: BLANK_TEMPLATE_ID,
    title: 'Blank workflow',
    purpose: 'Start from an empty pipeline and define every stage yourself.',
    expectedOutcome: 'Custom stage map',
    requiresSuppliedPlan: false,
    hasHumanGates: false,
    stageCount: 0,
    mode: null,
    isBlank: true,
    isAdvanced: true,
    isInstallableStarter: false,
  });
  return cards;
}

export function starterToTemplateCard(starter: DashboardStarterTemplate): WizardTemplateCard {
  return {
    id: starter.id,
    title: starter.id,
    purpose: starter.purpose,
    expectedOutcome: starter.category,
    requiresSuppliedPlan: false,
    hasHumanGates: false,
    stageCount: starter.stageCount,
    mode: 'sequential',
    isBlank: false,
    isAdvanced: false,
    isInstallableStarter: true,
  };
}

/** Catalog patterns plus installable starters (same card shape), omitting starters already in the catalog. */
export function buildPatternGroups(
  cards: readonly WizardTemplateCard[],
  starters: readonly DashboardStarterTemplate[],
): readonly { readonly outcome: string; readonly cards: readonly WizardTemplateCard[] }[] {
  const catalogIds = new Set(cards.filter((card) => !card.isBlank).map((card) => card.id));
  const starterCards = starters.filter((starter) => !catalogIds.has(starter.id)).map(starterToTemplateCard);
  const groups = groupTemplateCardsByOutcome(cards);
  if (starterCards.length === 0) {
    return groups;
  }
  return [{ outcome: 'Quick-start templates', cards: starterCards }, ...groups];
}

export function groupTemplateCardsByOutcome(
  cards: readonly WizardTemplateCard[],
): readonly { readonly outcome: string; readonly cards: readonly WizardTemplateCard[] }[] {
  const order: string[] = [];
  const map = new Map<string, WizardTemplateCard[]>();
  for (const card of cards) {
    if (card.isBlank) {
      continue;
    }
    const key = card.expectedOutcome;
    if (!map.has(key)) {
      order.push(key);
      map.set(key, []);
    }
    map.get(key)!.push(card);
  }
  const groups = order.map((outcome) => ({ outcome, cards: map.get(outcome)! }));
  const blank = cards.filter((c) => c.isBlank);
  if (blank.length > 0) {
    groups.push({ outcome: 'Advanced', cards: blank });
  }
  return groups;
}

export function findTemplateCard(
  cards: readonly WizardTemplateCard[],
  templateId: string | null,
): WizardTemplateCard | undefined {
  if (!templateId) {
    return undefined;
  }
  return cards.find((card) => card.id === templateId);
}

export function draftRequiresSuppliedPlan(
  draft: WizardDraft,
  cards: readonly WizardTemplateCard[],
): boolean {
  if (draft.planInput?.required === true) {
    return true;
  }
  return findTemplateCard(cards, draft.templateId)?.requiresSuppliedPlan === true;
}

export function clonePathEntries(entries: readonly PathEntry[]): PathEntry[] {
  return entries.map((entry) => ({ ...entry }));
}

export function cloneStages(stages: readonly WorkflowStageModel[]): WorkflowStageModel[] {
  return stages.map((stage) => {
    if (stage.kind === 'ordinary') {
      return {
        ...stage,
        dependsOn: [...stage.dependsOn],
        produces: clonePathEntries(stage.produces),
        requires: clonePathEntries(stage.requires),
        writeScopes: stage.writeScopes ? [...stage.writeScopes] : undefined,
        unsupportedKeys: [...stage.unsupportedKeys],
        planner: stage.planner ? { ...stage.planner } : undefined,
        loopCheck: stage.loopCheck ? { ...stage.loopCheck } : undefined,
        router: stage.router
          ? {
              ...stage.router,
              allowedTargets: [...stage.router.allowedTargets],
              terminalOutcomes: stage.router.terminalOutcomes
                ? [...stage.router.terminalOutcomes]
                : undefined,
            }
          : undefined,
      };
    }
    return {
      ...stage,
      dependsOn: [...stage.dependsOn],
      requires: stage.requires ? clonePathEntries(stage.requires) : undefined,
      unsupportedKeys: [...stage.unsupportedKeys],
      voters: stage.voters ? stage.voters.map((v) => ({ ...v })) : undefined,
      router: stage.router
        ? {
            ...stage.router,
            allowedTargets: [...stage.router.allowedTargets],
            terminalOutcomes: stage.router.terminalOutcomes
              ? [...stage.router.terminalOutcomes]
              : undefined,
          }
        : undefined,
    };
  });
}

export function stripHumanGateStages(stages: readonly WorkflowStageModel[]): WorkflowStageModel[] {
  const removed = new Set(
    stages
      .filter((s) => s.kind === 'supervisor' && HUMAN_GATE_TYPES.has(s.type))
      .map((s) => s.id),
  );
  if (removed.size === 0) {
    return cloneStages(stages);
  }
  return cloneStages(stages)
    .filter((s) => !removed.has(s.id))
    .map((s) => ({
      ...s,
      dependsOn: s.dependsOn.filter((dep) => !removed.has(dep)),
    }));
}

export function applyHumanGatePreference(
  stages: readonly WorkflowStageModel[],
  preferHumanGates: boolean,
): WorkflowStageModel[] {
  if (preferHumanGates) {
    return cloneStages(stages);
  }
  return stripHumanGateStages(stages);
}

export function buildStageMap(stages: readonly WorkflowStageModel[]): readonly StageMapEntry[] {
  return stages.map((stage) => ({
    id: stage.id,
    kind: stage.kind,
    type: stage.kind === 'supervisor' ? stage.type : undefined,
    dependsOn: [...stage.dependsOn],
  }));
}

export function canAdvanceFromStep1(draft: WizardDraft): boolean {
  return draft.templateId !== null && draft.templateId.length > 0;
}

export function canAdvanceFromStep2(draft: WizardDraft, requiresPlan: boolean): boolean {
  if (!draft.id || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(draft.id)) {
    return false;
  }
  if (draft.maxReworkIterations < 1 || draft.maxReworkIterations > 5) {
    return false;
  }
  if (requiresPlan && !draft.selectedPlanPath?.trim()) {
    return false;
  }
  return true;
}

export function canCreate(draft: WizardDraft, requiresPlan: boolean): boolean {
  return draft.step === 4 && canAdvanceFromStep2(draft, requiresPlan);
}

export function isDraftDirty(draft: WizardDraft): boolean {
  if (draft.templateId !== null) {
    return true;
  }
  if (draft.intent.trim() || draft.id.trim() || draft.name.trim() || draft.overview.trim()) {
    return true;
  }
  if (draft.taskDescription.trim() || draft.selectedPlanPath) {
    return true;
  }
  if (draft.stages.length > 0) {
    return true;
  }
  return false;
}

export function collectDraftWarnings(options: {
  readonly draft: WizardDraft;
  readonly requiresPlan: boolean;
  readonly templateHasHumanGates: boolean;
}): string[] {
  const warnings: string[] = [];
  const { draft, requiresPlan, templateHasHumanGates } = options;
  if (draft.templateLoadError) {
    warnings.push(draft.templateLoadError);
  }
  if (draft.unsupportedKeys.length > 0) {
    warnings.push(
      `Template carried unsupported keys that stay in raw YAML until structured: ${draft.unsupportedKeys.join(', ')}.`,
    );
  }
  if (requiresPlan && !draft.selectedPlanPath?.trim()) {
    warnings.push('This workflow requires a supplied plan source before Create is ready.');
  }
  if (templateHasHumanGates && !draft.preferHumanGates) {
    warnings.push('Human approval/input gates were removed from this local draft.');
  }
  if (draft.templateId === BLANK_TEMPLATE_ID && draft.stages.length === 0) {
    warnings.push('Blank workflow has no stages yet — add them in the structured editor.');
  }
  for (const stage of draft.stages) {
    if (stage.unsupportedKeys.length > 0) {
      warnings.push(`Stage ${stage.id} has unsupported keys: ${stage.unsupportedKeys.join(', ')}.`);
    }
  }
  return warnings;
}

export function suggestIdFromTemplate(templateId: string | null): string {
  if (!templateId || templateId === BLANK_TEMPLATE_ID) {
    return '';
  }
  return `my-${templateId}`;
}
