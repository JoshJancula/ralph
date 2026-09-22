import '../../angular-test-env';
import { provideRouter } from '@angular/router';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { computed, signal } from '@angular/core';
import { describe, expect, it, vi } from 'vitest';
import { WorkflowsListPageComponent } from './workflows-list.page';
import { WorkflowsFacade } from './workflows.facade';
import { CapabilitiesService } from './capabilities.service';
import type { WorkflowListItem } from './workflow.types';
import { matchesWorkflowCatalogSearch } from './workflow-catalog.helpers';

const CATALOG_BASE = {
  purpose: 'x',
  expectedOutcome: 'y',
  mode: 'dependency' as const,
  stageCount: 3,
  executableStageCount: 2,
  supervisorStageCount: 1,
  requiresSuppliedPlan: false,
  writes: true,
  hasHumanGates: false,
};

const WORKFLOWS: readonly WorkflowListItem[] = [
  {
    id: 'bug-fix',
    scope: 'bundled',
    effectiveScope: 'bundled',
    overview: 'Fix bugs',
    editable: false,
    catalog: { ...CATALOG_BASE, purpose: 'Fix bugs', writes: true },
  },
  {
    id: 'my-flow',
    scope: 'project',
    effectiveScope: 'project',
    overview: 'custom',
    editable: true,
    availableScopes: [
      { scope: 'project', overview: 'custom' },
      { scope: 'bundled', overview: 'base' },
    ],
    inheritsFrom: {
      scope: 'bundled',
      explanation: 'Project override of the bundled definition. The bundled original stays read-only.',
    },
    catalog: { ...CATALOG_BASE, purpose: 'custom', mode: 'sequential' },
  },
  {
    id: 'plan-delivery',
    scope: 'bundled',
    effectiveScope: 'bundled',
    overview: 'Execute supplied plan',
    editable: false,
    catalog: {
      ...CATALOG_BASE,
      purpose: 'Execute supplied plan',
      requiresSuppliedPlan: true,
      writes: true,
    },
  },
  {
    id: 'small-feature-delivery',
    scope: 'bundled',
    effectiveScope: 'bundled',
    overview: 'Deliver a localized feature',
    editable: false,
    catalog: { ...CATALOG_BASE, purpose: 'Deliver a localized feature', stageCount: 5, writes: true },
  },
  {
    id: 'human-verified-delivery',
    scope: 'global',
    effectiveScope: 'global',
    overview: 'Human gated delivery',
    editable: true,
    availableScopes: [
      { scope: 'global', overview: 'Human gated delivery' },
      { scope: 'bundled', overview: 'base' },
    ],
    inheritsFrom: {
      scope: 'bundled',
      explanation: 'Global override of the bundled definition. The bundled original stays read-only.',
    },
    catalog: {
      ...CATALOG_BASE,
      purpose: 'Human gated delivery',
      hasHumanGates: true,
      writes: true,
    },
  },
];

function fakeFacade(workflows: readonly WorkflowListItem[] = []) {
  const catalogSearch = signal('');
  const workflowsSignal = signal(workflows);
  const filteredWorkflows = computed(() =>
    workflowsSignal().filter((item) => matchesWorkflowCatalogSearch(item, catalogSearch())),
  );
  return {
    load: vi.fn(async () => undefined),
    stopRunsPolling: vi.fn(),
    workflows: workflowsSignal,
    catalogSearch,
    setCatalogSearch: (q: string) => catalogSearch.set(q),
    filteredWorkflows,
    loading: signal(false),
    error: signal<string | null>(null),
    isTriggering: () => false,
    start: vi.fn(async () => null),
    needsProjectSelection: () => false,
    requireProjectSelection: vi.fn(),
  };
}

function fakeCapabilities(workflowWrites = false) {
  return {
    load: vi.fn(),
    capabilities: signal({ workflowWrites, workflowRuns: workflowWrites, assistant: workflowWrites }),
  };
}

describe('WorkflowsListPageComponent', () => {
  async function build(facade: ReturnType<typeof fakeFacade>, capabilities: ReturnType<typeof fakeCapabilities>) {
    await TestBed.configureTestingModule({
      imports: [WorkflowsListPageComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: facade },
        { provide: CapabilitiesService, useValue: capabilities },
      ],
    }).compileComponents();
    const fixture: ComponentFixture<WorkflowsListPageComponent> = TestBed.createComponent(WorkflowsListPageComponent);
    fixture.detectChanges();
    return fixture;
  }

  it('calls facade.load() and capabilities.load() on init', async () => {
    const facade = fakeFacade();
    const capabilities = fakeCapabilities();
    await build(facade, capabilities);
    expect(facade.load).toHaveBeenCalled();
    expect(capabilities.load).toHaveBeenCalled();
  });

  it('groups workflows by source kind with precedence blurbs', async () => {
    const fixture = await build(fakeFacade(WORKFLOWS), fakeCapabilities());
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workflows-scope-bundled"]')?.textContent).toContain('bug-fix');
    expect(el.querySelector('[data-testid="workflows-scope-project"]')?.textContent).toContain('my-flow');
    expect(el.querySelector('[data-testid="workflows-scope-global"]')?.textContent).toContain('human-verified-delivery');
    expect(el.querySelector('[data-testid="workflows-precedence-lede"]')?.textContent).toMatch(/project overrides global/i);
  });

  it('shows source badges and override relationship for project/global variants', async () => {
    const fixture = await build(fakeFacade(WORKFLOWS), fakeCapabilities());
    const el: HTMLElement = fixture.nativeElement;
    const projectCard = el.querySelector('[data-workflow-id="my-flow"]') as HTMLElement;
    expect(projectCard.querySelector('[data-testid="workflow-source-badge"]')?.textContent).toContain('project');
    expect(projectCard.querySelector('[data-testid="workflow-inherit-hint"]')?.textContent).toContain(
      'bundled original stays read-only',
    );
    const bundledCard = el.querySelector('[data-workflow-id="bug-fix"]') as HTMLElement;
    expect(bundledCard.querySelector('[data-testid="workflow-readonly-badge"]')).not.toBeNull();
    expect(bundledCard.querySelector('[data-testid="workflow-inherit-hint"]')).toBeNull();
  });

  it('filters the catalog by search', async () => {
    const facade = fakeFacade(WORKFLOWS);
    const fixture = await build(facade, fakeCapabilities());
    facade.setCatalogSearch('supplied plan');
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-workflow-id="plan-delivery"]')).not.toBeNull();
    expect(el.querySelector('[data-workflow-id="bug-fix"]')).toBeNull();
  });

  it('lists the small-feature delivery template', async () => {
    const fixture = await build(fakeFacade(WORKFLOWS), fakeCapabilities());
    expect(fixture.nativeElement.querySelector('[data-workflow-id="small-feature-delivery"]')).not.toBeNull();
  });

  it('shows an empty state when there are no workflows', async () => {
    const fixture = await build(fakeFacade([]), fakeCapabilities());
    const empty = fixture.nativeElement.querySelector('[data-testid="workflows-empty"]');
    expect(empty).not.toBeNull();
    expect(empty?.textContent).toContain('No workflows found');
  });

  it('shows a search empty state when the query matches nothing', async () => {
    const facade = fakeFacade(WORKFLOWS);
    const fixture = await build(facade, fakeCapabilities());
    facade.setCatalogSearch('zzzz-no-match');
    fixture.detectChanges();
    const empty = fixture.nativeElement.querySelector('[data-testid="workflows-search-empty"]');
    expect(empty).not.toBeNull();
    expect(empty?.textContent).toMatch(/no workflows match your search/i);
  });

  it('hides "New workflow" when capabilities.workflowWrites is false', async () => {
    const fixture = await build(fakeFacade(WORKFLOWS), fakeCapabilities(false));
    expect(fixture.nativeElement.querySelector('[data-testid="workflows-new"]')).toBeNull();
  });

  it('shows "New workflow" when capabilities.workflowWrites is true', async () => {
    const fixture = await build(fakeFacade(WORKFLOWS), fakeCapabilities(true));
    expect(fixture.nativeElement.querySelector('[data-testid="workflows-new"]')).not.toBeNull();
  });

  it('surfaces facade.error()', async () => {
    const facade = fakeFacade(WORKFLOWS);
    facade.error.set('boom');
    const fixture = await build(facade, fakeCapabilities());
    expect(fixture.nativeElement.querySelector('[data-testid="route-error"]')?.textContent).toContain('boom');
  });

  it('retryLoad() reloads the catalog', async () => {
    const facade = fakeFacade(WORKFLOWS);
    const fixture = await build(facade, fakeCapabilities());
    facade.load.mockClear();
    fixture.componentInstance.retryLoad();
    await Promise.resolve();
    expect(facade.load).toHaveBeenCalledTimes(1);
  });

  it('onRunNow() starts a workflow when project selection is satisfied', async () => {
    const facade = fakeFacade(WORKFLOWS);
    const fixture = await build(facade, fakeCapabilities());
    fixture.componentInstance.onRunNow('bug-fix');
    await Promise.resolve();
    expect(facade.start).toHaveBeenCalledWith('bug-fix', { task: 'Run bug-fix' });
    expect(facade.requireProjectSelection).not.toHaveBeenCalled();
  });

  it('onRunNow() requires project selection when the facade needs it', async () => {
    const facade = fakeFacade(WORKFLOWS);
    facade.needsProjectSelection = () => true;
    const fixture = await build(facade, fakeCapabilities());
    fixture.componentInstance.onRunNow('bug-fix');
    await Promise.resolve();
    expect(facade.requireProjectSelection).toHaveBeenCalled();
    expect(facade.start).not.toHaveBeenCalled();
  });

  it('stops runs polling on destroy', async () => {
    const facade = fakeFacade(WORKFLOWS);
    const fixture = await build(facade, fakeCapabilities());
    fixture.destroy();
    expect(facade.stopRunsPolling).toHaveBeenCalled();
  });

  it('exposes scope labels and blurbs', async () => {
    const fixture = await build(fakeFacade(WORKFLOWS), fakeCapabilities());
    const page = fixture.componentInstance;
    expect(page.scopeLabel('project')).toBe('Project');
    expect(page.scopeBlurb('bundled')).toMatch(/framework defaults/i);
  });
});
