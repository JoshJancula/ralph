import type { OrdinaryStageModel, WorkflowDetail, WorkflowScope, WorkflowStageModel } from './workflow.types';

/** Multiple registered projects and no sidebar selection (dashboard "all workspaces" mode). */
export function isAllWorkspacesMode(workspaces: readonly { path: string }[], selectedPath: string | null): boolean {
  return workspaces.length > 1 && selectedPath === null;
}

export const SCOPE_LABEL: Record<WorkflowScope, string> = {
  project: 'Project',
  global: 'Global',
  bundled: 'Bundled',
};

export interface RoutingStageRow {
  readonly id: string;
  readonly kind: 'ordinary' | 'supervisor';
  readonly supervisorType?: string;
  readonly runtime?: string;
  readonly model?: string;
}

function stageRowFromModel(stage: WorkflowStageModel): RoutingStageRow {
  if (stage.kind === 'supervisor') {
    return { id: stage.id, kind: 'supervisor', supervisorType: stage.type };
  }
  return { id: stage.id, kind: 'ordinary', runtime: stage.runtime, model: stage.model };
}

function stagesFromInspect(inspect: unknown): readonly RoutingStageRow[] {
  if (!inspect || typeof inspect !== 'object') {
    return [];
  }
  const record = inspect as Record<string, unknown>;
  const stages = record['stages'];
  if (!Array.isArray(stages)) {
    return [];
  }
  const rows: RoutingStageRow[] = [];
  for (const entry of stages) {
    if (!entry || typeof entry !== 'object') {
      continue;
    }
    const stage = entry as Record<string, unknown>;
    const id = typeof stage['id'] === 'string' ? stage['id'] : '';
    if (!id) {
      continue;
    }
    const type = typeof stage['type'] === 'string' ? stage['type'] : undefined;
    if (type && type !== 'ordinary') {
      rows.push({ id, kind: 'supervisor', supervisorType: type });
      continue;
    }
    rows.push({
      id,
      kind: 'ordinary',
      runtime: typeof stage['runtime'] === 'string' ? stage['runtime'] : undefined,
      model: typeof stage['model'] === 'string' ? stage['model'] : undefined,
    });
  }
  return rows;
}

/** Ordinary and supervisor stage rows for routing UI (structured model, else inspect JSON). */
export function routingStagesFromDetail(detail: WorkflowDetail): readonly RoutingStageRow[] {
  if (detail.model?.stages?.length) {
    return detail.model.stages.map(stageRowFromModel);
  }
  const fromInspect = stagesFromInspect(detail.inspect);
  if (fromInspect.length > 0) {
    return fromInspect;
  }
  return [];
}

export function defaultsFromDetail(detail: WorkflowDetail): { runtime: string; model: string } {
  if (detail.model) {
    return {
      runtime: detail.model.defaultsRuntime ?? '',
      model: detail.model.defaultsModel ?? '',
    };
  }
  const inspect = detail.inspect;
  if (inspect && typeof inspect === 'object') {
    const defaults = (inspect as Record<string, unknown>)['defaults'];
    if (defaults && typeof defaults === 'object') {
      const d = defaults as Record<string, unknown>;
      return {
        runtime: typeof d['runtime'] === 'string' ? d['runtime'] : '',
        model: typeof d['model'] === 'string' ? d['model'] : '',
      };
    }
  }
  return { runtime: '', model: '' };
}

export function ordinaryStageFromDetail(detail: WorkflowDetail, stageId: string): OrdinaryStageModel | undefined {
  const stage = detail.model?.stages.find((entry) => entry.id === stageId);
  return stage?.kind === 'ordinary' ? stage : undefined;
}
