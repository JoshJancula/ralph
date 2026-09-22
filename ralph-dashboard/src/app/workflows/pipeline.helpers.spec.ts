import { describe, expect, it } from 'vitest';
import {
  addStage,
  blankStage,
  findDanglingDependency,
  findInvalidStageId,
  findStageCycle,
  isValidStageId,
  moveStage,
  nextStageId,
  removeStage,
  stagesFromTemplate,
  toggleDependency,
} from './pipeline.helpers';
import type { OrdinaryStageModel, SupervisorStageModel, WorkflowStageModel } from './workflow.types';

function ordinary(id: string, dependsOn: readonly string[] = []): OrdinaryStageModel {
  return { id, kind: 'ordinary', dependsOn, produces: [], requires: [], unsupportedKeys: [] };
}

function supervisor(id: string, dependsOn: readonly string[] = []): SupervisorStageModel {
  return { id, kind: 'supervisor', type: 'gate', dependsOn, unsupportedKeys: [] };
}

describe('pipeline.helpers', () => {
  describe('isValidStageId', () => {
    it('accepts lowercase kebab-case', () => {
      expect(isValidStageId('investigate')).toBe(true);
      expect(isValidStageId('plan-implementation')).toBe(true);
    });
    it('rejects uppercase, spaces, leading/trailing dashes, and empty', () => {
      expect(isValidStageId('Investigate')).toBe(false);
      expect(isValidStageId('plan implementation')).toBe(false);
      expect(isValidStageId('-plan')).toBe(false);
      expect(isValidStageId('plan-')).toBe(false);
      expect(isValidStageId('')).toBe(false);
    });
  });

  describe('nextStageId / blankStage', () => {
    it('finds the first unused stage-N id', () => {
      expect(nextStageId([])).toBe('stage-1');
      expect(nextStageId([ordinary('stage-1')])).toBe('stage-2');
      expect(nextStageId([ordinary('stage-1'), ordinary('stage-3')])).toBe('stage-2');
    });
    it('blankStage is an ordinary stage with empty dependsOn/produces/requires', () => {
      const stage = blankStage([]);
      expect(stage.kind).toBe('ordinary');
      expect(stage.id).toBe('stage-1');
      if (stage.kind === 'ordinary') {
        expect(stage.dependsOn).toEqual([]);
        expect(stage.produces).toEqual([]);
      }
    });
  });

  describe('addStage / removeStage', () => {
    it('addStage appends a blank stage', () => {
      const stages = addStage([ordinary('a')]);
      expect(stages).toHaveLength(2);
      expect(stages[1]?.id).toBe('stage-1');
    });

    it('removeStage drops the stage and cleans up dependsOn references to it', () => {
      const stages: WorkflowStageModel[] = [ordinary('a'), ordinary('b', ['a']), ordinary('c', ['a', 'b'])];
      const result = removeStage(stages, 'a');
      expect(result.map((s) => s.id)).toEqual(['b', 'c']);
      expect(result[0]?.dependsOn).toEqual([]);
      expect(result[1]?.dependsOn).toEqual(['b']);
    });
  });

  describe('moveStage', () => {
    it('swaps adjacent stages', () => {
      const stages = [ordinary('a'), ordinary('b'), ordinary('c')];
      const moved = moveStage(stages, 0, 1);
      expect(moved.map((s) => s.id)).toEqual(['b', 'a', 'c']);
    });
    it('is a no-op at the boundaries', () => {
      const stages = [ordinary('a'), ordinary('b')];
      expect(moveStage(stages, 0, -1).map((s) => s.id)).toEqual(['a', 'b']);
      expect(moveStage(stages, 1, 1).map((s) => s.id)).toEqual(['a', 'b']);
    });
  });

  describe('findInvalidStageId', () => {
    it('flags an invalid id', () => {
      expect(findInvalidStageId([ordinary('Bad Id')])).toBe('Bad Id');
    });
    it('flags a duplicate id', () => {
      expect(findInvalidStageId([ordinary('a'), ordinary('a')])).toBe('a');
    });
    it('returns null when every id is valid and unique', () => {
      expect(findInvalidStageId([ordinary('a'), ordinary('b')])).toBeNull();
    });
  });

  describe('findDanglingDependency', () => {
    it('flags a dependsOn referencing a nonexistent stage', () => {
      expect(findDanglingDependency([ordinary('a', ['missing'])])).toEqual({ stageId: 'a', dependency: 'missing' });
    });
    it('flags self-dependency', () => {
      expect(findDanglingDependency([ordinary('a', ['a'])])).toEqual({ stageId: 'a', dependency: 'a' });
    });
    it('returns null when every dependency resolves', () => {
      expect(findDanglingDependency([ordinary('a'), ordinary('b', ['a'])])).toBeNull();
    });
  });

  describe('findStageCycle', () => {
    it('detects a two-stage cycle', () => {
      const cycle = findStageCycle([ordinary('a', ['b']), ordinary('b', ['a'])]);
      expect(cycle).not.toBeNull();
      expect(cycle).toContain('a');
      expect(cycle).toContain('b');
    });
    it('returns null for an acyclic dependency graph, including through a supervisor stage', () => {
      const stages: WorkflowStageModel[] = [ordinary('a'), ordinary('b', ['a']), supervisor('gate-1', ['b'])];
      expect(findStageCycle(stages)).toBeNull();
    });
  });

  describe('toggleDependency', () => {
    it('adds and removes a dependency', () => {
      const stage = ordinary('b');
      const withDep = toggleDependency(stage, 'a', true);
      expect(withDep.dependsOn).toEqual(['a']);
      const withoutDep = toggleDependency(withDep, 'a', false);
      expect(withoutDep.dependsOn).toEqual([]);
    });
  });

  describe('stagesFromTemplate', () => {
    it('deep-copies dependsOn so mutating the result never touches the template', () => {
      const template = [ordinary('a'), ordinary('b', ['a'])];
      const copy = stagesFromTemplate(template);
      (copy[1] as OrdinaryStageModel).dependsOn = [...copy[1]!.dependsOn, 'extra'];
      expect(template[1]?.dependsOn).toEqual(['a']);
    });
  });
});
