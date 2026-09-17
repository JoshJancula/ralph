import '../../angular-test-env';
import { provideRouter, Router } from '@angular/router';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { of, throwError } from 'rxjs';
import { describe, expect, it, vi } from 'vitest';
import { WorkflowNewPageComponent } from './workflow-new.page';
import { WorkflowsFacade } from './workflows.facade';
import { WorkflowsApi } from './workflows-api.service';
import { CapabilitiesService } from './capabilities.service';
import { ApiService } from '../services/api.service';
import { TasksSchedulesService } from '../services/tasks-schedules.service';
import { ErrorDialogService } from '../services/error-dialog.service';
import { BLANK_TEMPLATE_ID } from './workflow-new-wizard.helpers';
import type { WorkflowDetail, WorkflowListItem } from './workflow.types';

function fakeFacade(workflows: WorkflowListItem[] = [
  {
    id: 'bug-fix',
    scope: 'bundled',
    overview: 'Fix a bug with review',
    editable: false,
    catalog: {
      purpose: 'Fix a bug with review',
      expectedOutcome: 'Independently verified delivery',
      mode: 'dependency',
      stageCount: 1,
      executableStageCount: 1,
      supervisorStageCount: 0,
      requiresSuppliedPlan: false,
      writes: true,
      hasHumanGates: false,
    },
  },
  {
    id: 'plan-delivery',
    scope: 'bundled',
    overview: 'Execute an operator-supplied plan',
    editable: false,
    catalog: {
      purpose: 'Execute an operator-supplied plan',
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
    id: 'human-verified-delivery',
    scope: 'bundled',
    overview: 'Deliver with human gates',
    editable: false,
    catalog: {
      purpose: 'Deliver with human gates',
      expectedOutcome: 'Independently verified delivery',
      mode: 'dependency',
      stageCount: 8,
      executableStageCount: 5,
      supervisorStageCount: 3,
      requiresSuppliedPlan: false,
      writes: true,
      hasHumanGates: true,
    },
  },
]) {
  return {
    load: vi.fn(async () => undefined),
    workflows: signal<readonly WorkflowListItem[]>(workflows),
    saving: signal(false),
    error: signal<string | null>(null),
    create: vi.fn(async () => true),
    markBuilderDirty: vi.fn(),
    loadModels: vi.fn(async (runtime: string) =>
      runtime === 'codex'
        ? [{ id: 'o4-mini', label: 'o4-mini' }]
        : [{ id: 'sonnet', label: 'sonnet' }],
    ),
  };
}

function fakeCapabilities(workflowWrites = true) {
  return {
    load: vi.fn(),
    capabilities: signal({ workflowWrites, workflowRuns: workflowWrites, assistant: workflowWrites }),
  };
}

const TEMPLATE_DETAIL: WorkflowDetail = {
  id: 'bug-fix',
  scope: 'bundled',
  raw: '---\nname: bug-fix\n---\n',
  sha256: 'x',
  inspect: {},
  mermaid: '',
  model: {
    name: 'bug-fix',
    mode: 'dependency',
    stages: [{ id: 'investigate', kind: 'ordinary', dependsOn: [], produces: [], requires: [], unsupportedKeys: [] }],
    todos: [],
    unsupportedKeys: [],
    body: '\n',
    sourceRaw: '---\nname: bug-fix\n---\n',
  },
};

const PLAN_DELIVERY_DETAIL: WorkflowDetail = {
  id: 'plan-delivery',
  scope: 'bundled',
  raw: '---\nname: plan-delivery\n---\n',
  sha256: 'y',
  inspect: {},
  mermaid: '',
  model: {
    name: 'plan-delivery',
    overview: 'Execute an operator-supplied Ralph plan',
    mode: 'dependency',
    planInput: { stage: 'implement', required: true },
    stages: [
      { id: 'implement', kind: 'ordinary', dependsOn: [], produces: [], requires: [], unsupportedKeys: [] },
      { id: 'review', kind: 'ordinary', dependsOn: ['implement'], produces: [], requires: [], unsupportedKeys: [] },
      { id: 'integrate', kind: 'supervisor', type: 'integrate', dependsOn: ['review'], unsupportedKeys: [] },
    ],
    todos: [],
    unsupportedKeys: [],
    body: '\n',
    sourceRaw: '---\nname: plan-delivery\n---\n',
  },
};

const HUMAN_GATES_DETAIL: WorkflowDetail = {
  id: 'human-verified-delivery',
  scope: 'bundled',
  raw: '---\nname: human-verified-delivery\n---\n',
  sha256: 'z',
  inspect: {},
  mermaid: '',
  model: {
    name: 'human-verified-delivery',
    mode: 'dependency',
    stages: [
      { id: 'implement', kind: 'ordinary', dependsOn: [], produces: [], requires: [], unsupportedKeys: [] },
      {
        id: 'approve-plan',
        kind: 'supervisor',
        type: 'approval',
        dependsOn: ['implement'],
        changesTarget: 'implement',
        unsupportedKeys: [],
      },
      { id: 'qa', kind: 'ordinary', dependsOn: ['approve-plan'], produces: [], requires: [], unsupportedKeys: [] },
    ],
    todos: [],
    unsupportedKeys: [],
    body: '\n',
    sourceRaw: '---\nname: human-verified-delivery\n---\n',
  },
};

describe('WorkflowNewPageComponent', () => {
  async function build(
    facade: ReturnType<typeof fakeFacade>,
    capabilities: ReturnType<typeof fakeCapabilities>,
    apiImpl?: { getWorkflow: ReturnType<typeof vi.fn> },
  ) {
    const api = apiImpl ?? {
      getWorkflow: vi.fn((id: string) => {
        if (id === 'plan-delivery') {
          return of(PLAN_DELIVERY_DETAIL);
        }
        if (id === 'human-verified-delivery') {
          return of(HUMAN_GATES_DETAIL);
        }
        return of(TEMPLATE_DETAIL);
      }),
    };
    const plansApi = {
      fetchPlanIndex: vi.fn(() =>
        of({
          items: [
            {
              id: 'leaf-1',
              name: 'Leaf Plan',
              path: 'plans/leaf-1.plan.md',
              projectRoot: '/proj',
              type: 'leaf' as const,
              isProject: true,
              checkboxProgress: { completed: 0, total: 2 },
              lastActivityMs: 0,
              hasLatestRun: false,
            },
          ],
          pageInfo: { hasMore: false, total: 1 },
          appliedFilters: {},
          counts: { total: 1, filtered: 1 },
        }),
      ),
    };
    const taskSchedulesApi = {
      templates: vi.fn(() => of([])),
      installTemplate: vi.fn(() => of(undefined)),
    };
    await TestBed.configureTestingModule({
      imports: [WorkflowNewPageComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: facade },
        { provide: WorkflowsApi, useValue: api },
        { provide: CapabilitiesService, useValue: capabilities },
        { provide: ApiService, useValue: plansApi },
        { provide: TasksSchedulesService, useValue: taskSchedulesApi },
        { provide: ErrorDialogService, useValue: { displayError: vi.fn().mockResolvedValue(undefined) } },
      ],
    }).compileComponents();
    const fixture: ComponentFixture<WorkflowNewPageComponent> = TestBed.createComponent(WorkflowNewPageComponent);
    fixture.detectChanges();
    return { fixture, api, plansApi, taskSchedulesApi };
  }

  it('hides the form and shows a notice when workflow writes are disabled', async () => {
    const { fixture } = await build(fakeFacade(), fakeCapabilities(false));
    expect(fixture.nativeElement.querySelector('[data-testid="builder-writes-disabled"]')).not.toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="wizard-next"]')).toBeNull();
  });

  it('step 1 shows template cards including blank advanced mode', async () => {
    const { fixture } = await build(fakeFacade(), fakeCapabilities());
    expect(fixture.nativeElement.querySelector('[data-testid="wizard-panel-template"]')).not.toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="wizard-template-bug-fix"]')).not.toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="wizard-template-plan-delivery"]')).not.toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="wizard-template-blank"]')).not.toBeNull();
    expect(fixture.componentInstance.canGoNext()).toBe(false);
  });

  it('choosing a pattern advances to requirements without pressing Next', async () => {
    const { fixture, api } = await build(fakeFacade(), fakeCapabilities());
    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'bug-fix')!;
    await fixture.componentInstance.onPatternChosen(card);
    fixture.detectChanges();
    expect(fixture.componentInstance.draft().step).toBe(2);
    expect(api.getWorkflow).toHaveBeenCalledWith('bug-fix');
    expect(fixture.nativeElement.querySelector('[data-testid="wizard-panel-requirements"]')).not.toBeNull();
  });

  it('installable quick-start templates install then advance like other patterns', async () => {
    const facade = fakeFacade();
    const taskSchedulesApi = {
      templates: vi.fn(() =>
        of([
          {
            id: 'market-pulse',
            category: 'Trade analysis',
            purpose: 'Research-only pulse',
            outputs: 'Brief',
            safety: 'Analysis only',
            installable: true,
            stageCount: 1,
          },
        ]),
      ),
      installTemplate: vi.fn(() => of({ id: 'market-pulse', created: true })),
    };
    const api = { getWorkflow: vi.fn(() => of(TEMPLATE_DETAIL)) };
    await TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [WorkflowNewPageComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: facade },
        { provide: WorkflowsApi, useValue: api },
        { provide: CapabilitiesService, useValue: fakeCapabilities() },
        { provide: ApiService, useValue: { fetchPlanIndex: vi.fn(() => of({ items: [], pageInfo: { hasMore: false, total: 0 }, appliedFilters: {}, counts: { total: 0, filtered: 0 } })) } },
        { provide: TasksSchedulesService, useValue: taskSchedulesApi },
        { provide: ErrorDialogService, useValue: { displayError: vi.fn().mockResolvedValue(undefined) } },
      ],
    }).compileComponents();
    const fixture = TestBed.createComponent(WorkflowNewPageComponent);
    fixture.detectChanges();
    const starter = fixture.componentInstance
      .patternGroups()
      .find((g) => g.outcome === 'Quick-start templates')
      ?.cards.find((c) => c.id === 'market-pulse');
    expect(starter).toBeTruthy();
    await fixture.componentInstance.onPatternChosen(starter!);
    expect(taskSchedulesApi.installTemplate).toHaveBeenCalledWith('market-pulse');
    expect(facade.load).toHaveBeenCalled();
    expect(fixture.componentInstance.draft().step).toBe(2);
    expect(fixture.componentInstance.draft().templateId).toBe('market-pulse');
  });

  it('template selection enables Next and seeds stages without YAML editing', async () => {
    const { fixture, api } = await build(fakeFacade(), fakeCapabilities());
    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'bug-fix')!;
    fixture.componentInstance.selectTemplate(card);
    expect(fixture.componentInstance.canGoNext()).toBe(true);
    await fixture.componentInstance.goNext();
    expect(api.getWorkflow).toHaveBeenCalledWith('bug-fix');
    expect(fixture.componentInstance.draft().step).toBe(2);
    expect(fixture.componentInstance.draft().stages).toHaveLength(1);
    expect(fixture.componentInstance.draft().stages[0]?.id).toBe('investigate');
    expect(fixture.componentInstance.draft().id).toBe('my-bug-fix');
  });

  it('uses the runtime model catalog for workflow defaults', async () => {
    const facade = fakeFacade();
    const { fixture } = await build(facade, fakeCapabilities());
    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'bug-fix')!;
    fixture.componentInstance.selectTemplate(card);
    await fixture.componentInstance.goNext();
    fixture.componentInstance.onDefaultsRuntimeChange('codex');
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();

    expect(facade.loadModels).toHaveBeenCalledWith('codex');
    const select = fixture.nativeElement.querySelector('[data-testid="workflow-model-select"]') as HTMLSelectElement;
    expect(select).not.toBeNull();
    expect(Array.from(select.options).map((option) => option.value)).toEqual(['o4-mini', '__custom__']);
  });

  it('supplied-plan templates block Next/Create without a plan source', async () => {
    const { fixture } = await build(fakeFacade(), fakeCapabilities());
    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'plan-delivery')!;
    fixture.componentInstance.selectTemplate(card);
    await fixture.componentInstance.goNext();
    fixture.detectChanges();
    expect(fixture.componentInstance.requiresSuppliedPlan()).toBe(true);
    expect(fixture.componentInstance.canGoNext()).toBe(false);
    expect(fixture.nativeElement.querySelector('[data-testid="wizard-plan-required"]')).not.toBeNull();

    fixture.componentInstance.onPlanSourceChange('plans/leaf-1.plan.md');
    expect(fixture.componentInstance.canGoNext()).toBe(true);

    await fixture.componentInstance.goNext();
    await fixture.componentInstance.goNext();
    expect(fixture.componentInstance.draft().step).toBe(4);

    fixture.componentInstance.patchDraft({ selectedPlanPath: null, selectedPlanName: null });
    expect(fixture.componentInstance.canSubmit()).toBe(false);
  });

  it('stage-map review lists generated stages and warnings', async () => {
    const { fixture } = await build(fakeFacade(), fakeCapabilities());
    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'plan-delivery')!;
    fixture.componentInstance.selectTemplate(card);
    await fixture.componentInstance.goNext();
    fixture.componentInstance.onPlanSourceChange('plans/leaf-1.plan.md');
    await fixture.componentInstance.goNext();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="wizard-panel-stage-map"]')).not.toBeNull();
    expect(fixture.componentInstance.stageMap()).toHaveLength(3);
    expect(fixture.nativeElement.querySelector('[data-stage-id="implement"]')).not.toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="wizard-review-stage-count"]')?.textContent).toContain('3');
  });

  it('blank advanced mode skips template seeding and opens an empty stage map', async () => {
    const { fixture, api } = await build(fakeFacade(), fakeCapabilities());
    const blank = fixture.componentInstance.templateCards().find((c) => c.id === BLANK_TEMPLATE_ID)!;
    fixture.componentInstance.selectTemplate(blank);
    await fixture.componentInstance.goNext();
    expect(api.getWorkflow).not.toHaveBeenCalled();
    expect(fixture.componentInstance.draft().stages).toEqual([]);
    fixture.componentInstance.patchDraft({ id: 'custom-flow' });
    await fixture.componentInstance.goNext();
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="wizard-stage-map-empty"]')).not.toBeNull();
    expect(fixture.componentInstance.draft().warnings.some((w) => /Blank workflow/.test(w))).toBe(true);
  });

  it('flags an invalid id and disables Next on requirements', async () => {
    const { fixture } = await build(fakeFacade(), fakeCapabilities());
    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'bug-fix')!;
    fixture.componentInstance.selectTemplate(card);
    await fixture.componentInstance.goNext();
    fixture.componentInstance.patchDraft({ id: 'Not Valid' });
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="builder-id-error"]')).not.toBeNull();
    expect(fixture.componentInstance.canGoNext()).toBe(false);
  });

  it('submit() calls facade.create only on step 4 when ready', async () => {
    const facade = fakeFacade();
    const { fixture } = await build(facade, fakeCapabilities());
    const router = TestBed.inject(Router);
    const navigateSpy = vi.spyOn(router, 'navigate').mockResolvedValue(true);

    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'bug-fix')!;
    fixture.componentInstance.selectTemplate(card);
    await fixture.componentInstance.goNext();
    await fixture.componentInstance.goNext();
    await fixture.componentInstance.goNext();
    expect(fixture.componentInstance.draft().step).toBe(4);
    await fixture.componentInstance.submit();
    expect(facade.create).toHaveBeenCalledWith(
      expect.objectContaining({ id: 'my-bug-fix', scope: 'project', mode: 'dependency' }),
    );
    expect(navigateSpy).toHaveBeenCalledWith(['/workflows', 'my-bug-fix']);
  });

  it('submit() is a no-op when canSubmit() is false', async () => {
    const facade = fakeFacade();
    const { fixture } = await build(facade, fakeCapabilities());
    await fixture.componentInstance.submit();
    expect(facade.create).not.toHaveBeenCalled();
  });

  it('Back retains draft state; Cancel asks to discard when dirty', async () => {
    const { fixture } = await build(fakeFacade(), fakeCapabilities());
    const router = TestBed.inject(Router);
    const navigateSpy = vi.spyOn(router, 'navigate').mockResolvedValue(true);

    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'bug-fix')!;
    fixture.componentInstance.selectTemplate(card);
    await fixture.componentInstance.goNext();
    const id = fixture.componentInstance.draft().id;
    fixture.componentInstance.goBack();
    expect(fixture.componentInstance.draft().step).toBe(1);
    expect(fixture.componentInstance.draft().id).toBe(id);
    expect(fixture.componentInstance.draft().templateId).toBe('bug-fix');

    fixture.componentInstance.onCancel();
    expect(fixture.componentInstance.confirmDiscard()).toBe(true);
    expect(navigateSpy).not.toHaveBeenCalled();
    fixture.componentInstance.confirmDiscardDraft();
    expect(navigateSpy).toHaveBeenCalledWith(['/workflows']);
  });

  it('preferHumanGates=false strips approval stages from the local draft', async () => {
    const { fixture } = await build(fakeFacade(), fakeCapabilities());
    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'human-verified-delivery')!;
    fixture.componentInstance.selectTemplate(card);
    await fixture.componentInstance.goNext();
    expect(fixture.componentInstance.draft().stages.some((s) => s.id === 'approve-plan')).toBe(true);
    fixture.componentInstance.onPreferHumanGatesChange(false);
    expect(fixture.componentInstance.draft().stages.some((s) => s.id === 'approve-plan')).toBe(false);
    expect(fixture.componentInstance.draft().stages.find((s) => s.id === 'qa')?.dependsOn).not.toContain('approve-plan');
  });

  it('seedFromTemplate leaves stages empty when the source has no structured model', async () => {
    const api = { getWorkflow: vi.fn(() => of({ ...TEMPLATE_DETAIL, model: undefined, unsupportedKeys: ['x'] })) };
    const { fixture } = await build(fakeFacade(), fakeCapabilities(), api);
    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'bug-fix')!;
    fixture.componentInstance.selectTemplate(card);
    await fixture.componentInstance.goNext();
    expect(fixture.componentInstance.draft().stages).toEqual([]);
    expect(fixture.componentInstance.draft().unsupportedKeys).toContain('x');
  });

  it('seedFromTemplate swallows an API failure', async () => {
    const api = { getWorkflow: vi.fn(() => throwError(() => new Error('boom'))) };
    const { fixture } = await build(fakeFacade(), fakeCapabilities(), api);
    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'bug-fix')!;
    fixture.componentInstance.selectTemplate(card);
    await expect(fixture.componentInstance.goNext()).resolves.toBeUndefined();
    expect(fixture.componentInstance.draft().warnings.some((w) => /Could not load template/.test(w))).toBe(true);
  });

  it('submit() does not navigate when facade.create resolves false', async () => {
    const facade = fakeFacade();
    facade.create.mockResolvedValue(false);
    const { fixture } = await build(facade, fakeCapabilities());
    const router = TestBed.inject(Router);
    const navigateSpy = vi.spyOn(router, 'navigate').mockResolvedValue(true);
    const card = fixture.componentInstance.templateCards().find((c) => c.id === 'bug-fix')!;
    fixture.componentInstance.selectTemplate(card);
    await fixture.componentInstance.goNext();
    await fixture.componentInstance.goNext();
    await fixture.componentInstance.goNext();
    await fixture.componentInstance.submit();
    expect(navigateSpy).not.toHaveBeenCalled();
  });
});
