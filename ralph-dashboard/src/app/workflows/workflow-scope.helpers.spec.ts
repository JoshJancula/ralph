import '../../angular-test-env';
import { describe, expect, it } from 'vitest';
import {
  SCOPE_LABEL,
  defaultsFromDetail,
  isAllWorkspacesMode,
  ordinaryStageFromDetail,
  routingStagesFromDetail,
} from './workflow-scope.helpers';
import type { WorkflowDetail } from './workflow.types';

describe('workflow-scope.helpers', () => {
  it('routingStagesFromDetail reads ordinary stages from inspect JSON for raw-mode workflows', () => {
    const detail: WorkflowDetail = {
      id: 'assessment',
      scope: 'global',
      raw: '---\nname: assessment\n---\n',
      sha256: 'x',
      inspect: {
        stages: [
          { id: 'inspect', runtime: 'cursor', model: 'composer' },
          { id: 'assessment-gate', type: 'gate' },
        ],
      },
      mermaid: '',
      unsupportedKeys: ['pipeline.extraField'],
    };
    const stages = routingStagesFromDetail(detail);
    expect(stages.map((stage) => stage.id)).toEqual(['inspect', 'assessment-gate']);
    expect(stages[0].kind).toBe('ordinary');
    expect(stages[1].kind).toBe('supervisor');
  });

  it('defaultsFromDetail reads defaults from inspect when no structured model exists', () => {
    const detail: WorkflowDetail = {
      id: 'assessment',
      scope: 'global',
      raw: '',
      sha256: 'x',
      inspect: { defaults: { runtime: 'claude', model: 'sonnet' } },
      mermaid: '',
    };
    expect(defaultsFromDetail(detail)).toEqual({ runtime: 'claude', model: 'sonnet' });
  });

  it('isAllWorkspacesMode is true only with multiple workspaces and no sidebar selection', () => {
    const workspaces = [{ path: '/a' }, { path: '/b' }];
    expect(isAllWorkspacesMode(workspaces, null)).toBe(true);
    expect(isAllWorkspacesMode(workspaces, '/a')).toBe(false);
    expect(isAllWorkspacesMode([{ path: '/a' }], null)).toBe(false);
  });

  it('routingStagesFromDetail prefers structured model stages', () => {
    const detail: WorkflowDetail = {
      id: 'wf',
      scope: 'project',
      raw: '',
      sha256: 'x',
      mermaid: '',
      model: {
        mode: 'sequential',
        defaultsRuntime: 'cursor',
        defaultsModel: 'composer',
        stages: [
          { kind: 'ordinary', id: 'build', runtime: 'cursor', model: 'composer' },
          { kind: 'supervisor', id: 'gate', type: 'gate' },
        ],
      },
    };
    const stages = routingStagesFromDetail(detail);
    expect(stages).toEqual([
      { id: 'build', kind: 'ordinary', runtime: 'cursor', model: 'composer' },
      { id: 'gate', kind: 'supervisor', supervisorType: 'gate' },
    ]);
  });

  it('routingStagesFromDetail ignores malformed inspect entries', () => {
    const detail: WorkflowDetail = {
      id: 'wf',
      scope: 'bundled',
      raw: '',
      sha256: 'x',
      mermaid: '',
      inspect: {
        stages: [null, { id: '' }, { id: 'ok', type: 'approval' }, { id: 'plain', runtime: 1 }],
      },
    };
    expect(routingStagesFromDetail(detail)).toEqual([
      { id: 'ok', kind: 'supervisor', supervisorType: 'approval' },
      { id: 'plain', kind: 'ordinary', runtime: undefined, model: undefined },
    ]);
  });

  it('defaultsFromDetail reads structured model defaults', () => {
    const detail: WorkflowDetail = {
      id: 'wf',
      scope: 'project',
      raw: '',
      sha256: 'x',
      mermaid: '',
      model: {
        mode: 'dependency',
        defaultsRuntime: 'claude',
        defaultsModel: 'opus',
        stages: [],
      },
    };
    expect(defaultsFromDetail(detail)).toEqual({ runtime: 'claude', model: 'opus' });
  });

  it('defaultsFromDetail returns empty strings when no defaults exist', () => {
    const detail: WorkflowDetail = {
      id: 'wf',
      scope: 'bundled',
      raw: '',
      sha256: 'x',
      mermaid: '',
    };
    expect(defaultsFromDetail(detail)).toEqual({ runtime: '', model: '' });
  });

  it('ordinaryStageFromDetail returns only ordinary stages from the model', () => {
    const detail: WorkflowDetail = {
      id: 'wf',
      scope: 'project',
      raw: '',
      sha256: 'x',
      mermaid: '',
      model: {
        mode: 'sequential',
        defaultsRuntime: '',
        defaultsModel: '',
        stages: [
          { kind: 'ordinary', id: 'build', runtime: 'cursor', model: 'composer' },
          { kind: 'supervisor', id: 'gate', type: 'gate' },
        ],
      },
    };
    expect(ordinaryStageFromDetail(detail, 'build')?.id).toBe('build');
    expect(ordinaryStageFromDetail(detail, 'gate')).toBeUndefined();
    expect(ordinaryStageFromDetail(detail, 'missing')).toBeUndefined();
  });

  it('SCOPE_LABEL maps every scope', () => {
    expect(SCOPE_LABEL.project).toBe('Project');
    expect(SCOPE_LABEL.global).toBe('Global');
    expect(SCOPE_LABEL.bundled).toBe('Bundled');
  });
});
