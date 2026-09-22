import '../../angular-test-env';
import { provideRouter, ActivatedRoute, Router, convertToParamMap } from '@angular/router';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { of } from 'rxjs';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { WorkflowEditPageComponent } from './workflow-edit.page';
import { workflowEditCanDeactivate } from './workflow-edit.guard';
import { WorkflowsFacade } from './workflows.facade';
import { CapabilitiesService } from './capabilities.service';
import { ConfirmationDialogService } from '../services/confirmation-dialog.service';
import type { WorkflowDetail } from './workflow.types';

const STRUCTURED_DETAIL: WorkflowDetail = {
  id: 'my-flow',
  scope: 'project',
  raw: '---\nname: my-flow\n---\n',
  sha256: 'sha-1',
  inspect: {},
  mermaid: '',
  model: {
    name: 'my-flow',
    mode: 'dependency',
    maxParallel: 1,
    maxReworkIterations: 1,
    stages: [{ id: 'a', kind: 'ordinary', dependsOn: [], produces: [], requires: [], unsupportedKeys: [] }],
    todos: [],
    unsupportedKeys: [],
    body: '\n',
    sourceRaw: '---\nname: my-flow\n---\n',
  },
};

const RAW_MODE_DETAIL: WorkflowDetail = {
  id: 'legacy-flow',
  scope: 'project',
  raw: '---\nname: legacy-flow\nverificationProfiles: []\n---\n',
  sha256: 'sha-2',
  inspect: {},
  mermaid: '',
  unsupportedKeys: ['pipeline.extraField'],
};

const BUNDLED_DETAIL: WorkflowDetail = { ...STRUCTURED_DETAIL, id: 'bug-fix', scope: 'bundled' };

function fakeFacade(detail: WorkflowDetail | null) {
  return {
    openDetail: vi.fn(async () => undefined),
    stopRunsPolling: vi.fn(),
    markEditDirty: vi.fn(),
    editDirty: vi.fn(() => false),
    selected: signal(detail),
    selectedScope: signal<WorkflowDetail['scope'] | null>(detail?.scope ?? null),
    runtimes: signal([{ id: 'claude', installed: true }]),
    writableScope: () => (detail?.scope === 'bundled' ? undefined : (detail?.scope as 'project' | 'global' | undefined)),
    error: signal<string | null>(null),
    saving: signal(false),
    needsProjectSelection: signal(false),
    update: vi.fn(async () => 'ok' as const),
    customize: vi.fn(async () => ({ scope: 'project' as const, sha256: 'x', created: true })),
  };
}

function fakeCapabilities(workflowWrites = true) {
  return { load: vi.fn(), capabilities: signal({ workflowWrites, workflowRuns: workflowWrites, assistant: workflowWrites }) };
}

function fakeConfirmation(confirmed = true) {
  return { confirm: vi.fn(async () => confirmed) };
}

describe('WorkflowEditPageComponent', () => {
  async function build(
    facade: ReturnType<typeof fakeFacade>,
    capabilities = fakeCapabilities(),
    id = facade.selected()?.id ?? 'my-flow',
    confirmation = fakeConfirmation(),
  ) {
    await TestBed.configureTestingModule({
      imports: [WorkflowEditPageComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: facade },
        { provide: CapabilitiesService, useValue: capabilities },
        { provide: ConfirmationDialogService, useValue: confirmation },
        {
          provide: ActivatedRoute,
          useValue: { paramMap: of(convertToParamMap({ id })), queryParamMap: of(convertToParamMap({})) },
        },
      ],
    }).compileComponents();
    const fixture: ComponentFixture<WorkflowEditPageComponent> = TestBed.createComponent(WorkflowEditPageComponent);
    fixture.detectChanges();
    return fixture;
  }

  it('loads the workflow named by the :id route param', async () => {
    const facade = fakeFacade(null);
    await build(facade);
    expect(facade.openDetail).toHaveBeenCalledWith('my-flow', undefined);
  });

  it('bundled workflows offer global and project customization actions', async () => {
    const facade = fakeFacade(BUNDLED_DETAIL);
    const fixture = await build(facade, fakeCapabilities(), 'bug-fix');
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="edit-bundled-note"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="edit-customize-global"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="edit-customize-project"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="edit-save"]')).toBeNull();

    const router = TestBed.inject(Router);
    const navigateSpy = vi.spyOn(router, 'navigate').mockResolvedValue(true);
    (el.querySelector('[data-testid="edit-customize-project"]') as HTMLButtonElement).click();
    await Promise.resolve();
    expect(facade.customize).toHaveBeenCalledWith('bug-fix', { targetScope: 'project', sourceScope: 'bundled' });
    expect(navigateSpy).toHaveBeenCalledWith(['/workflows', 'bug-fix', 'edit'], { queryParams: { scope: 'project', customizing: '1' } });
  });

  it('hides save controls when capabilities.workflowWrites is false', async () => {
    const facade = fakeFacade(STRUCTURED_DETAIL);
    const fixture = await build(facade, fakeCapabilities(false));
    expect(fixture.nativeElement.querySelector('[data-testid="edit-writes-disabled"]')).not.toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="edit-save"]')).toBeNull();
  });

  it('structured model: renders the stage editor and saves via facade.update with the loaded sha256', async () => {
    const facade = fakeFacade(STRUCTURED_DETAIL);
    const fixture = await build(facade);
    const router = TestBed.inject(Router);
    const navigateSpy = vi.spyOn(router, 'navigate').mockResolvedValue(true);
    expect(fixture.nativeElement.querySelector('ralph-workflow-stage-editor')).not.toBeNull();

    await fixture.componentInstance.save('my-flow', false);
    expect(facade.update).toHaveBeenCalledWith('my-flow', expect.objectContaining({ sha256: 'sha-1' }), 'project');
    expect(navigateSpy).toHaveBeenCalledWith(['/workflows', 'my-flow']);
  });

  it('shows the reload-or-overwrite prompt on a 409 conflict', async () => {
    const facade = fakeFacade(STRUCTURED_DETAIL);
    facade.update.mockResolvedValue('conflict');
    const fixture = await build(facade);
    await fixture.componentInstance.save('my-flow', false);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="edit-conflict"]')).not.toBeNull();
  });

  it('shows inspect diagnostics inline on a 422', async () => {
    const facade = fakeFacade(STRUCTURED_DETAIL);
    facade.update.mockResolvedValue('invalid');
    facade.error.set('Workflow failed validation: Error: bad stage');
    const fixture = await build(facade);
    await fixture.componentInstance.save('my-flow', false);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="edit-invalid-diagnostics"]')?.textContent).toContain('bad stage');
  });

  it('reload() clears the conflict flag and reloads the workflow', async () => {
    const facade = fakeFacade(STRUCTURED_DETAIL);
    const fixture = await build(facade);
    fixture.componentInstance.conflict.set(true);
    await fixture.componentInstance.reload('my-flow');
    expect(fixture.componentInstance.conflict()).toBe(false);
    expect(facade.openDetail).toHaveBeenCalledWith('my-flow', undefined);
  });

  it('save(id, true) re-fetches the current sha256 before overwriting', async () => {
    const facade = fakeFacade(STRUCTURED_DETAIL);
    const fixture = await build(facade);
    await fixture.componentInstance.save('my-flow', true);
    expect(facade.openDetail).toHaveBeenCalledWith('my-flow', undefined);
    expect(facade.update).toHaveBeenCalledWith('my-flow', expect.objectContaining({ sha256: 'sha-1' }), 'project');
  });

  it('save()/saveRaw() are no-ops when nothing is selected', async () => {
    const facade = fakeFacade(null);
    const fixture = await build(facade);
    await fixture.componentInstance.save('my-flow', false);
    await fixture.componentInstance.saveRaw('my-flow', false);
    expect(facade.update).not.toHaveBeenCalled();
  });

  it('raw mode: renders a raw textarea and saves via facade.update with { raw }', async () => {
    const facade = fakeFacade(RAW_MODE_DETAIL);
    const fixture = await build(facade, fakeCapabilities(), 'legacy-flow');
    const router = TestBed.inject(Router);
    const navigateSpy = vi.spyOn(router, 'navigate').mockResolvedValue(true);
    expect(fixture.nativeElement.querySelector('[data-testid="edit-raw-mode-note"]')).not.toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="edit-raw-textarea"]')).not.toBeNull();

    fixture.componentInstance.rawText.set('---\nname: changed\n---\n');
    await fixture.componentInstance.saveRaw('legacy-flow', false);
    expect(facade.update).toHaveBeenCalledWith(
      'legacy-flow',
      { sha256: 'sha-2', raw: '---\nname: changed\n---\n' },
      'project',
    );
    expect(navigateSpy).toHaveBeenCalledWith(['/workflows', 'legacy-flow']);
  });

  it('manages verification profiles, steps, and timeouts in seconds', async () => {
    const facade = fakeFacade(STRUCTURED_DETAIL);
    const fixture = await build(facade);
    const comp = fixture.componentInstance;

    // Add profile
    comp.addVerificationProfile();
    expect(comp.verificationProfiles()).toHaveLength(1);
    expect(comp.verificationProfiles()[0]?.steps).toHaveLength(1);
    expect(comp.verificationProfiles()[0]?.steps[0]?.timeout).toBe(120);

    // Add step to profile
    comp.addVerificationStep(0);
    expect(comp.verificationProfiles()[0]?.steps).toHaveLength(2);

    // Update timeout in seconds
    comp.onStepTimeout(0, 1, 300);
    expect(comp.verificationProfiles()[0]?.steps[1]?.timeout).toBe(300);

    // Remove first step
    comp.removeVerificationStep(0, 0);
    expect(comp.verificationProfiles()[0]?.steps).toHaveLength(1);
    expect(comp.verificationProfiles()[0]?.steps[0]?.timeout).toBe(300);

    // Remove profile
    comp.removeVerificationProfile(0);
    expect(comp.verificationProfiles()).toHaveLength(0);
  });

  it('populates ordinary stages for planInput consumer stage selection', async () => {
    const facade = fakeFacade(STRUCTURED_DETAIL);
    const fixture = await build(facade);
    const comp = fixture.componentInstance;

    expect(comp.ordinaryStages().map((s) => s.id)).toEqual(['a']);
    expect(comp.hasOrdinaryStage('a')).toBe(true);
    expect(comp.hasOrdinaryStage('unknown')).toBe(false);
  });
});

describe('workflowEditCanDeactivate', () => {
  it('allows navigation without a confirmation dialog when there are no unsaved changes', async () => {
    const facade = fakeFacade(STRUCTURED_DETAIL);
    facade.editDirty.mockReturnValue(false);
    const confirmation = fakeConfirmation();
    TestBed.configureTestingModule({ providers: [{ provide: WorkflowsFacade, useValue: facade }, { provide: ConfirmationDialogService, useValue: confirmation }] });
    const result = TestBed.runInInjectionContext(() => workflowEditCanDeactivate(null as never, null as never, null as never, null as never));
    expect(result).toBe(true);
    expect(confirmation.confirm).not.toHaveBeenCalled();
  });

  it('uses the Ionic confirmation dialog to decide whether to discard changes', async () => {
    const facade = fakeFacade(STRUCTURED_DETAIL);
    facade.editDirty.mockReturnValue(true);
    const confirmation = fakeConfirmation(false);
    TestBed.configureTestingModule({ providers: [{ provide: WorkflowsFacade, useValue: facade }, { provide: ConfirmationDialogService, useValue: confirmation }] });
    const result = TestBed.runInInjectionContext(() => workflowEditCanDeactivate(null as never, null as never, null as never, null as never));
    await expect(result).resolves.toBe(false);
    expect(confirmation.confirm).toHaveBeenCalledWith({
      header: 'Discard unsaved changes?',
      message: 'Your edits will be lost if you leave this page.',
      confirmText: 'Discard',
    });
  });
});
