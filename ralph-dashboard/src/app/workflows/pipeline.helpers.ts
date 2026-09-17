/**
 * Ported from trade-beacon's pipeline.helpers.ts with Ralph stage semantics:
 * no `type` enum, no `order` field (array position is the order), no
 * `isFinalOutput`/`outputFileName`. See port-design.md "Field mapping".
 */
import type { OrdinaryStageModel, WorkflowStageModel } from './workflow.types';

export const STAGE_ID_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

export function isValidStageId(id: string): boolean {
  return STAGE_ID_PATTERN.test(id);
}

function blankOrdinaryStage(id: string): OrdinaryStageModel {
  return {
    id,
    kind: 'ordinary',
    dependsOn: [],
    produces: [],
    requires: [],
    unsupportedKeys: [],
  };
}

export function nextStageId(existing: readonly WorkflowStageModel[], startAt = 1): string {
  let n = startAt;
  const ids = new Set(existing.map((stage) => stage.id));
  while (ids.has(`stage-${n}`)) {
    n += 1;
  }
  return `stage-${n}`;
}

export function blankStage(existing: readonly WorkflowStageModel[]): WorkflowStageModel {
  return blankOrdinaryStage(nextStageId(existing));
}

export function addStage(stages: readonly WorkflowStageModel[]): WorkflowStageModel[] {
  return [...stages, blankStage(stages)];
}

export function removeStage(stages: readonly WorkflowStageModel[], stageId: string): WorkflowStageModel[] {
  return stages
    .filter((stage) => stage.id !== stageId)
    .map((stage) => ({ ...stage, dependsOn: stage.dependsOn.filter((dep) => dep !== stageId) }));
}

export function moveStage(stages: readonly WorkflowStageModel[], index: number, direction: -1 | 1): WorkflowStageModel[] {
  const target = index + direction;
  if (index < 0 || index >= stages.length || target < 0 || target >= stages.length) {
    return [...stages];
  }
  const next = stages.slice();
  const current = next[index];
  const swap = next[target];
  if (!current || !swap) {
    return [...stages];
  }
  next[index] = swap;
  next[target] = current;
  return next;
}

/**
 * Unique, non-empty stage ids matching STAGE_ID_PATTERN. Returns the first
 * violation found, or null when every id is valid and unique.
 */
export function findInvalidStageId(stages: readonly WorkflowStageModel[]): string | null {
  const seen = new Set<string>();
  for (const stage of stages) {
    if (!stage.id || !isValidStageId(stage.id)) {
      return stage.id || '(empty)';
    }
    if (seen.has(stage.id)) {
      return stage.id;
    }
    seen.add(stage.id);
  }
  return null;
}

/** Every dependsOn entry must reference an existing stage id (and not itself). */
export function findDanglingDependency(stages: readonly WorkflowStageModel[]): { stageId: string; dependency: string } | null {
  const ids = new Set(stages.map((stage) => stage.id));
  for (const stage of stages) {
    for (const dep of stage.dependsOn) {
      if (dep === stage.id || !ids.has(dep)) {
        return { stageId: stage.id, dependency: dep };
      }
    }
  }
  return null;
}

/** Depth-first cycle detection over dependsOn edges. Returns the cycle path, or null when acyclic. */
export function findStageCycle(stages: readonly WorkflowStageModel[]): readonly string[] | null {
  const ids = new Set(stages.map((stage) => stage.id));
  const byId = new Map(stages.map((stage) => [stage.id, stage] as const));
  const visiting = new Set<string>();
  const visited = new Set<string>();

  function visit(id: string, path: string[]): readonly string[] | null {
    if (visiting.has(id)) {
      const cycleStart = path.indexOf(id);
      return path.slice(cycleStart).concat(id);
    }
    if (visited.has(id) || !ids.has(id)) {
      return null;
    }
    visiting.add(id);
    path.push(id);
    const stage = byId.get(id);
    if (stage) {
      for (const dependency of stage.dependsOn) {
        const cycle = visit(dependency, path);
        if (cycle) {
          return cycle;
        }
      }
    }
    path.pop();
    visiting.delete(id);
    visited.add(id);
    return null;
  }

  for (const stage of stages) {
    const cycle = visit(stage.id, []);
    if (cycle) {
      return cycle;
    }
  }
  return null;
}

export function toggleDependency(stage: OrdinaryStageModel, dependencyId: string, enabled: boolean): OrdinaryStageModel {
  const current = new Set(stage.dependsOn);
  if (enabled) {
    current.add(dependencyId);
  } else {
    current.delete(dependencyId);
  }
  return { ...stage, dependsOn: [...current] };
}

export function stagesFromTemplate(templateStages: readonly WorkflowStageModel[]): WorkflowStageModel[] {
  return templateStages.map((stage) => ({ ...stage, dependsOn: [...stage.dependsOn] }));
}
