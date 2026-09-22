import { describe, expect, it } from 'vitest';
import {
  buildStageInspectorView,
  extractInstructionsFromStageBlock,
  listIncludeFragments,
  mapStageSourceRange,
  renderInstructionsWithIncludes,
} from './stage-inspector.helpers';
import type { WorkflowDetail } from './workflow.types';

const FEATURE_RAW = `---
name: feature-delivery
pipeline:
  stages:
    - id: investigate
      instructions: |
        Investigate {{TASK}} as a bounded study.
        {{INCLUDE:investigation-rigor}}
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/feature-investigation.md
          required: true
    - id: implement
      instructions: |
        Execute the plan.
      writeScopes: ["**"]
      dependsOn:
        - investigate
    - id: qa-gate
      type: gate
      profile: qa-verdict
      dependsOn:
        - qa
    - id: human-ack
      type: approval
      question: Ship this?
      changesTarget: implement
      dependsOn:
        - qa-gate
---
`;

const DETAIL: WorkflowDetail = {
  id: 'feature-delivery',
  scope: 'bundled',
  raw: FEATURE_RAW,
  sha256: 'abc',
  inspect: {
    stages: [
      {
        id: 'investigate',
        type: 'agent',
        dependsOn: [],
        requires: [],
        produces: [
          {
            path: '.ralph-workspace/artifacts/{{ARTIFACT_NS}}/feature-investigation.md',
            required: true,
            schema: null,
          },
        ],
        runtime: null,
        model: null,
        writeScopes: null,
        workspaceMode: null,
        planFrom: null,
        planner: null,
        loopBackTo: null,
        changesTarget: null,
        question: null,
        onExhausted: null,
        agentGitAccess: null,
      },
      {
        id: 'implement',
        type: 'agent',
        dependsOn: ['investigate'],
        requires: [],
        produces: [],
        writeScopes: '["**"]',
        workspaceMode: 'snapshot',
        planFrom: 'plan-implementation',
        planner: null,
        loopBackTo: null,
        changesTarget: null,
        question: null,
        onExhausted: null,
        runtime: 'claude',
        model: null,
        agentGitAccess: 'off',
      },
      {
        id: 'qa-gate',
        type: 'gate',
        dependsOn: ['qa'],
        requires: [{ path: 'qa-verdict.json', required: true, schema: null }],
        produces: [],
        writeScopes: null,
        workspaceMode: null,
        planFrom: null,
        planner: null,
        loopBackTo: null,
        changesTarget: null,
        question: null,
        onExhausted: null,
        runtime: null,
        model: null,
        agentGitAccess: null,
      },
      {
        id: 'human-ack',
        type: 'approval',
        dependsOn: ['qa-gate'],
        requires: [],
        produces: [],
        writeScopes: null,
        workspaceMode: null,
        planFrom: null,
        planner: null,
        loopBackTo: null,
        changesTarget: 'implement',
        question: 'Ship this?',
        onExhausted: null,
        runtime: null,
        model: null,
        agentGitAccess: null,
      },
    ],
  },
  mermaid: '',
  displayGraph: {
    workflowId: 'feature-delivery',
    mode: 'dependency',
    sourceKind: 'bundled',
    sourcePath: '/tmp/feature-delivery.workflow.md',
    maxReworkIterations: 2,
    nodes: [
      {
        id: 'investigate',
        label: 'investigate',
        kind: 'agent',
        stageType: 'agent',
        authored: true,
        derivedFrom: 'stage',
        planRole: null,
        waveIndex: 0,
        loopBackTo: null,
        changesTarget: null,
      },
      {
        id: 'implement',
        label: 'implement',
        kind: 'plan-consumer',
        stageType: 'agent',
        authored: true,
        derivedFrom: 'stage',
        planRole: 'execute',
        waveIndex: 1,
        loopBackTo: null,
        changesTarget: null,
      },
      {
        id: 'qa-gate',
        label: 'qa-gate',
        kind: 'gate',
        stageType: 'gate',
        authored: true,
        derivedFrom: 'stage',
        planRole: null,
        waveIndex: 2,
        loopBackTo: null,
        changesTarget: null,
      },
      {
        id: 'human-ack',
        label: 'human-ack',
        kind: 'approval',
        stageType: 'approval',
        authored: true,
        derivedFrom: 'stage',
        planRole: null,
        waveIndex: 3,
        loopBackTo: null,
        changesTarget: 'implement',
      },
    ],
    edges: [],
    waves: [['investigate'], ['implement'], ['qa-gate'], ['human-ack']],
  },
};

describe('stage-inspector.helpers', () => {
  it('maps YAML source lines to an authored stage block', () => {
    const range = mapStageSourceRange(FEATURE_RAW, 'qa-gate');
    expect(range).not.toBeNull();
    expect(range!.startLine).toBeGreaterThan(0);
    expect(range!.text).toContain('id: qa-gate');
    expect(range!.text).toContain('type: gate');
    expect(range!.text).toContain('profile: qa-verdict');
    expect(range!.endLine).toBeGreaterThanOrEqual(range!.startLine);
  });

  it('extracts instructions and INCLUDE fragment names', () => {
    const range = mapStageSourceRange(FEATURE_RAW, 'investigate');
    const instructions = extractInstructionsFromStageBlock(range!.text);
    expect(instructions).toContain('Investigate {{TASK}}');
    expect(listIncludeFragments(instructions!)).toEqual(['investigation-rigor']);
  });

  it('links or expands INCLUDE fragments in markdown', () => {
    const linked = renderInstructionsWithIncludes('Hello {{INCLUDE:plan-budget}}');
    expect(linked.includes[0]?.name).toBe('plan-budget');
    expect(linked.includes[0]?.body).toBeNull();
    expect(linked.markdown).toContain('Include fragment');

    const expanded = renderInstructionsWithIncludes('Hello {{INCLUDE:plan-budget}}', new Map([['plan-budget', 'Keep plans small.']]));
    expect(expanded.includes[0]?.body).toContain('Keep plans small');
    expect(expanded.markdown).toContain('Keep plans small');
  });

  it('builds agent, gate, and approval inspector views', () => {
    const agent = buildStageInspectorView(DETAIL, 'investigate');
    expect(agent?.role).toBe('agent');
    expect(agent?.writeCapability).toBe('read-only');
    expect(agent?.goal).toContain('Investigate');
    expect(agent?.includes.map((entry) => entry.name)).toContain('investigation-rigor');
    expect(agent?.source?.text).toContain('id: investigate');

    const writer = buildStageInspectorView(DETAIL, 'implement');
    expect(writer?.writeCapability).toBe('mutation');
    expect(writer?.planFrom).toBe('plan-implementation');

    const gate = buildStageInspectorView(DETAIL, 'qa-gate');
    expect(gate?.role).toBe('supervisor');
    expect(gate?.gateBehavior?.kind).toBe('gate');
    expect(gate?.gateBehavior?.profile).toBe('qa-verdict');
    expect(gate?.writeCapability).toBe('supervisor');

    const approval = buildStageInspectorView(DETAIL, 'human-ack');
    expect(approval?.role).toBe('supervisor');
    expect(approval?.gateBehavior?.kind).toBe('approval');
    expect(approval?.gateBehavior?.question).toBe('Ship this?');
    expect(approval?.gateBehavior?.changesTarget).toBe('implement');
  });
});
