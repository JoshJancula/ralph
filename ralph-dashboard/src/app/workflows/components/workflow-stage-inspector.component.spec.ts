import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';
import '../../../angular-test-env';
import { SelectedStageStore } from '../selected-stage.store';
import { WorkflowStageInspectorComponent } from './workflow-stage-inspector.component';
import type { WorkflowDetail } from '../workflow.types';

const RAW = `---
pipeline:
  stages:
    - id: investigate
      instructions: |
        Investigate the defect.
        {{INCLUDE:investigation-rigor}}
      produces:
        - path: out.md
          required: true
    - id: qa-gate
      type: gate
      profile: qa-verdict
      dependsOn:
        - investigate
    - id: human-ack
      type: approval
      question: Proceed?
      changesTarget: investigate
---
`;

const DETAIL: WorkflowDetail = {
  id: 'demo',
  scope: 'bundled',
  raw: RAW,
  sha256: 'x',
  inspect: {
    stages: [
      {
        id: 'investigate',
        type: 'agent',
        dependsOn: [],
        requires: [],
        produces: [{ path: 'out.md', required: true, schema: null }],
        writeScopes: null,
        runtime: null,
        model: null,
        planFrom: null,
        planner: null,
        loopBackTo: null,
        changesTarget: null,
        question: null,
        onExhausted: null,
        workspaceMode: null,
        agentGitAccess: null,
      },
      {
        id: 'qa-gate',
        type: 'gate',
        dependsOn: ['investigate'],
        requires: [],
        produces: [],
        writeScopes: null,
        runtime: null,
        model: null,
        planFrom: null,
        planner: null,
        loopBackTo: null,
        changesTarget: null,
        question: null,
        onExhausted: null,
        workspaceMode: null,
        agentGitAccess: null,
      },
      {
        id: 'human-ack',
        type: 'approval',
        dependsOn: ['qa-gate'],
        requires: [],
        produces: [],
        writeScopes: null,
        runtime: null,
        model: null,
        planFrom: null,
        planner: null,
        loopBackTo: null,
        changesTarget: 'investigate',
        question: 'Proceed?',
        onExhausted: null,
        workspaceMode: null,
        agentGitAccess: null,
      },
    ],
  },
  mermaid: '',
  displayGraph: {
    workflowId: 'demo',
    mode: 'dependency',
    sourceKind: 'bundled',
    sourcePath: '/tmp/demo.workflow.md',
    maxReworkIterations: null,
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
        id: 'qa-gate',
        label: 'qa-gate',
        kind: 'gate',
        stageType: 'gate',
        authored: true,
        derivedFrom: 'stage',
        planRole: null,
        waveIndex: 1,
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
        waveIndex: 2,
        loopBackTo: null,
        changesTarget: 'investigate',
      },
    ],
    edges: [],
    waves: [['investigate'], ['qa-gate'], ['human-ack']],
  },
};

describe('WorkflowStageInspectorComponent', () => {
  let fixture: ComponentFixture<WorkflowStageInspectorComponent>;
  let store: SelectedStageStore;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [WorkflowStageInspectorComponent],
      providers: [SelectedStageStore],
    }).compileComponents();
    store = TestBed.inject(SelectedStageStore);
    fixture = TestBed.createComponent(WorkflowStageInspectorComponent);
    fixture.componentRef.setInput('workflow', DETAIL);
  });

  it('selects an agent stage and maps YAML source lines', () => {
    store.select('demo', 'investigate');
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="inspector-stage-id"]')?.textContent).toContain('investigate');
    expect(el.querySelector('[data-testid="inspector-role"]')?.textContent).toContain('Agent');
    expect(el.querySelector('[data-testid="inspector-write-capability"]')?.textContent).toMatch(/Read-only/i);
    expect(el.querySelector('[data-testid="inspector-includes"]')?.textContent).toContain('investigation-rigor');

    (el.querySelector('[data-testid="inspector-tab-source"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    const source = el.querySelector('[data-testid="inspector-source-code"]');
    expect(source?.textContent).toContain('id: investigate');
    expect(el.querySelector('[data-testid="inspector-source-range"]')?.textContent).toMatch(/lines \d+–\d+/);
    expect(el.querySelector('[data-line]')?.getAttribute('data-line')).toMatch(/^\d+$/);
  });

  it('renders gate stages as supervisor controls', () => {
    store.select('demo', 'qa-gate');
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="inspector-role"]')?.textContent).toContain('Supervisor');
    expect(el.querySelector('[data-testid="inspector-gate-behavior"]')?.textContent).toContain('gate');
    expect(el.querySelector('[data-testid="inspector-gate-behavior"]')?.textContent).toContain('qa-verdict');
    expect(el.querySelector('[data-testid="inspector-write-capability"]')?.textContent).toMatch(/Supervisor/i);
  });

  it('renders approval stages as supervisor controls with changesTarget', () => {
    store.select('demo', 'human-ack');
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="inspector-role"]')?.textContent).toContain('Supervisor');
    expect(el.querySelector('[data-testid="inspector-gate-behavior"]')?.textContent).toContain('approval');
    expect(el.querySelector('[data-testid="inspector-gate-behavior"]')?.textContent).toContain('Proceed?');
    expect(el.querySelector('[data-testid="inspector-gate-behavior"]')?.textContent).toContain('investigate');
  });

  it('shows empty state when no stage is selected or workflow id mismatches', () => {
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="inspector-empty"]')).not.toBeNull();

    store.select('other-workflow', 'investigate');
    fixture.detectChanges();
    expect(fixture.componentInstance.view()).toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="inspector-empty"]')).not.toBeNull();
  });

  it('filters source lines and expands INCLUDE fragments when provided', () => {
    const fragments = new Map([['investigation-rigor', 'Be thorough.']]);
    fixture.componentRef.setInput('fragments', fragments);
    store.select('demo', 'investigate');
    fixture.detectChanges();

    (fixture.nativeElement.querySelector('[data-testid="inspector-tab-source"]') as HTMLButtonElement).click();
    fixture.detectChanges();

    fixture.componentInstance.sourceQuery.set('Investigate the defect');
    fixture.detectChanges();
    const matchLine = fixture.nativeElement.querySelector('.source-line.match');
    expect(matchLine).not.toBeNull();

    fixture.componentInstance.sourceQuery.set('zzz-no-match');
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelectorAll('.source-line.match').length).toBe(0);
  });

  it('copySource writes clipboard text and handles missing clipboard', async () => {
    store.select('demo', 'investigate');
    fixture.detectChanges();

    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    });

    await fixture.componentInstance.copySource();
    expect(writeText).toHaveBeenCalled();
    expect(fixture.componentInstance.copied()).toBe(true);

    writeText.mockRejectedValueOnce(new Error('denied'));
    await fixture.componentInstance.copySource();
    expect(fixture.componentInstance.copied()).toBe(false);

    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: undefined,
    });
    await fixture.componentInstance.copySource();
    expect(writeText).toHaveBeenCalledTimes(2);
  });

  it('copySource no-ops when view has no source text', async () => {
    fixture.detectChanges();
    const writeText = vi.fn();
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    });
    await fixture.componentInstance.copySource();
    expect(writeText).not.toHaveBeenCalled();
  });

  it('clears selection when the inspector is destroyed', () => {
    store.select('demo', 'investigate');
    fixture.detectChanges();
    expect(store.stageId()).toBe('investigate');
    fixture.destroy();
    expect(store.stageId()).toBeNull();
  });

  it('renders empty instructions and source html when markdown/source are absent', () => {
    store.select('demo', 'qa-gate');
    fixture.detectChanges();
    expect(fixture.componentInstance.view()?.instructionsMarkdown).toBeFalsy();
    expect(fixture.componentInstance.instructionsHtml()).toBeTruthy();

    const noSource: WorkflowDetail = {
      ...DETAIL,
      raw: '---\nname: demo\n---\n',
    };
    fixture.componentRef.setInput('workflow', noSource);
    store.select('demo', 'qa-gate');
    fixture.detectChanges();
    expect(fixture.componentInstance.view()?.source).toBeNull();
    expect(fixture.componentInstance.sourceHtml()).toBeTruthy();
  });

  it('resets copied flag after clipboard success timeout', async () => {
    vi.useFakeTimers();
    store.select('demo', 'investigate');
    fixture.detectChanges();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    });
    await fixture.componentInstance.copySource();
    expect(fixture.componentInstance.copied()).toBe(true);
    vi.advanceTimersByTime(1500);
    expect(fixture.componentInstance.copied()).toBe(false);
    vi.useRealTimers();
  });

  it('toSafeHtml bypasses DOMParser when unavailable', () => {
    store.select('demo', 'investigate');
    fixture.detectChanges();
    const original = globalThis.DOMParser;
    // @ts-expect-error intentional coverage of missing DOMParser
    delete globalThis.DOMParser;
    const html = (
      fixture.componentInstance as unknown as { toSafeHtml: (value: string) => unknown }
    ).toSafeHtml('<b>ok</b>');
    expect(html).toBeTruthy();
    globalThis.DOMParser = original;
  });
});
