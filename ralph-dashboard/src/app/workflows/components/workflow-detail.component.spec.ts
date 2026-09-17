import '../../../angular-test-env';
import { provideRouter } from '@angular/router';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { WorkflowDetailComponent } from './workflow-detail.component';
import { WorkflowsFacade } from '../workflows.facade';
import { CapabilitiesService } from '../capabilities.service';
import type { WorkflowDetail } from '../workflow.types';

function fakeFacade() {
  const triggering = new Set<string>();
  return {
    isTriggering: (id: string) => triggering.has(id),
    start: vi.fn(async () => null),
    stopRunsPolling: vi.fn(),
    runs: () => [],
    runsLoading: () => false,
    saving: signal(false),
    needsProjectSelection: signal(false),
    customize: vi.fn(async () => ({ scope: 'project' as const, sha256: 'x', created: true })),
    openDetail: vi.fn(async () => undefined),
    remove: vi.fn(async () => true),
    writableScope: () => undefined,
    runtimes: signal([{ id: 'claude', installed: true }]),
    loadModels: vi.fn(async () => []),
  };
}

function fakeCapabilities(workflowRuns = true) {
  return { capabilities: signal({ workflowWrites: workflowRuns, workflowRuns, assistant: workflowRuns }) };
}

const BASE_DETAIL: WorkflowDetail = {
  id: 'bug-fix',
  scope: 'bundled',
  raw: '---\nname: bug-fix\n---\nbody\n',
  sha256: 'abc',
  inspect: {},
  mermaid: '',
  unsupportedKeys: ['pipeline.extraField'],
};

describe('WorkflowDetailComponent', () => {
  let fixture: ComponentFixture<WorkflowDetailComponent>;

  async function build(capabilities = fakeCapabilities()): Promise<void> {
    await TestBed.configureTestingModule({
      imports: [WorkflowDetailComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: fakeFacade() },
        { provide: CapabilitiesService, useValue: capabilities },
      ],
    }).compileComponents();
    fixture = TestBed.createComponent(WorkflowDetailComponent);
  }

  beforeEach(async () => {
    await build();
  });

  it('renders id, scope badge, and a raw-mode note when the file has no structured model', () => {
    fixture.componentRef.setInput('workflow', BASE_DETAIL);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workflow-name"]')?.textContent).toContain('bug-fix');
    expect(el.querySelector('[data-testid="workflow-scope"]')?.textContent).toContain('bundled');
    expect(el.querySelector('[data-testid="workflow-raw-mode-note"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="workflow-stages"]')).toBeNull();
  });

  it('renders the overview and stage list when a structured model is present', () => {
    const detail: WorkflowDetail = {
      ...BASE_DETAIL,
      unsupportedKeys: [],
      model: {
        name: 'bug-fix',
        overview: 'Fix a defect',
        mode: 'dependency',
        stages: [
          { id: 'investigate', kind: 'ordinary', dependsOn: [], produces: [], requires: [], unsupportedKeys: [] },
          { id: 'implement', kind: 'ordinary', dependsOn: ['investigate'], produces: [], requires: [], unsupportedKeys: [] },
        ],
        todos: [],
        unsupportedKeys: [],
        body: '\n',
        sourceRaw: BASE_DETAIL.raw,
      },
    };
    fixture.componentRef.setInput('workflow', detail);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workflow-overview"]')?.textContent).toContain('Fix a defect');
    expect(el.querySelector('[data-testid="workflow-raw-mode-note"]')).toBeNull();
    expect(el.textContent).toContain('depends on: investigate');
  });

  it('toggles between the graph and raw file views', () => {
    fixture.componentRef.setInput('workflow', BASE_DETAIL);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workflow-raw"]')).toBeNull();
    (el.querySelector('[data-testid="toggle-raw"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="workflow-raw"]')?.textContent).toContain('name: bug-fix');
  });

  it('renders a selectable display graph when displayGraph is present', () => {
    const detail: WorkflowDetail = {
      ...BASE_DETAIL,
      displayGraph: {
        workflowId: 'bug-fix',
        mode: 'dependency',
        sourceKind: 'bundled',
        sourcePath: '/tmp/bug-fix.workflow.md',
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
        ],
        edges: [{ from: 'investigate', to: 'implement', kind: 'dependency', label: null, scheduleEdge: true }],
        waves: [['investigate'], ['implement']],
      },
    };
    fixture.componentRef.setInput('workflow', detail);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workflow-display-graph"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="workflow-stage-inspector"]')).not.toBeNull();
    expect(el.textContent).not.toContain('Graph unavailable');
    (el.querySelector('[data-node-id="investigate"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="inspector-stage-id"]')?.textContent).toContain('investigate');
  });

  it('renders graph diagnostics instead of Graph unavailable when graphError is set', () => {
    const detail: WorkflowDetail = {
      ...BASE_DETAIL,
      graphError: {
        code: 'inspect-failed',
        message: 'Could not build a display graph for "bug-fix".',
        diagnostics: 'Error: invalid workflow at line 12',
        sourcePath: '/tmp/bug-fix.workflow.md',
        sourceKind: 'project',
        line: 12,
        column: null,
      },
    };
    fixture.componentRef.setInput('workflow', detail);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workflow-graph-error"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="workflow-graph-diagnostics"]')?.textContent).toContain('line 12');
    expect(el.textContent).not.toContain('Graph unavailable');
  });

  it('clicking Start opens the start-workflow dialog for this workflow', () => {
    fixture.componentRef.setInput('workflow', BASE_DETAIL);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="start-dialog"]')).toBeNull();
    (el.querySelector('[data-testid="detail-run-now"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="start-dialog"]')).not.toBeNull();
  });

  it('keeps Start enabled when the global selector is set to all projects', () => {
    const facade = TestBed.inject(WorkflowsFacade) as unknown as ReturnType<typeof fakeFacade>;
    facade.needsProjectSelection.set(true);
    fixture.componentRef.setInput('workflow', BASE_DETAIL);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    const start = el.querySelector('[data-testid="detail-run-now"]') as HTMLButtonElement;
    expect(start.disabled).toBe(false);
    start.click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="start-dialog"]')).not.toBeNull();
  });

  it('bundled workflows show global and project customization actions', () => {
    fixture.componentRef.setInput('workflow', BASE_DETAIL);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="detail-customize-global"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="detail-customize-project"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="detail-bundled-precedence"]')).not.toBeNull();
  });

  it('shows definition-copy switcher and shadow notes when available', () => {
    const detail: WorkflowDetail = {
      ...BASE_DETAIL,
      scope: 'project',
      effectiveScope: 'project',
      availableScopes: [
        { scope: 'project', overview: 'project winner' },
        { scope: 'global', overview: 'global layer' },
      ],
      shadowedBy: { scope: 'project' },
      unsupportedKeys: [],
      model: {
        name: 'bug-fix',
        mode: 'dependency',
        stages: [],
        todos: [],
        unsupportedKeys: [],
        body: '\n',
        sourceRaw: BASE_DETAIL.raw,
      },
    };
    fixture.componentRef.setInput('workflow', detail);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    const layers = el.querySelector('[data-testid="detail-scope-layers"]') as HTMLElement;
    expect(layers).not.toBeNull();
    expect(layers.textContent).toContain('View definition copy');
    expect(layers.textContent).toContain('does not change which copy runs');
    const selected = el.querySelector('[data-testid="detail-scope-project"]') as HTMLButtonElement;
    expect(selected.getAttribute('aria-checked')).toBe('true');
    expect(selected.classList.contains('active')).toBe(true);
    expect(el.querySelector('[data-testid="detail-shadowed-note"]')?.textContent).toContain('project');
    expect(el.querySelector('[data-testid="detail-edit-global"]')).not.toBeNull();
  });

  it('hides Start and the dialog entirely when capabilities.workflowRuns is false', async () => {
    TestBed.resetTestingModule();
    await build(fakeCapabilities(false));
    fixture.componentRef.setInput('workflow', BASE_DETAIL);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="detail-run-now"]')).toBeNull();
    expect(el.querySelector('ralph-start-workflow-dialog')).toBeNull();
  });
});
