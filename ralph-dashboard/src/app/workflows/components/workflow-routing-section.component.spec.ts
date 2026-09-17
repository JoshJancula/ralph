import '../../../angular-test-env';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { WorkflowRoutingSectionComponent } from './workflow-routing-section.component';
import { WorkflowsFacade } from '../workflows.facade';
import type { WorkflowDetail } from '../workflow.types';

const RAW_ASSESSMENT: WorkflowDetail = {
  id: 'assessment',
  scope: 'global',
  raw: '---\nname: assessment\n---\n',
  sha256: 'sha-assessment',
  inspect: {
    defaults: { runtime: 'claude', model: 'sonnet' },
    stages: [
      { id: 'inspect', runtime: 'cursor', model: 'composer' },
      { id: 'qa-gate', type: 'gate' },
    ],
  },
  mermaid: '',
  unsupportedKeys: ['pipeline.extraField'],
};

function fakeFacade(overrides: Partial<ReturnType<typeof baseFacade>> = {}) {
  return { ...baseFacade(), ...overrides };
}

function baseFacade() {
  return {
    runtimes: signal([{ id: 'claude', installed: true }, { id: 'cursor', installed: true }]),
    saving: signal(false),
    error: signal<string | null>(null),
    writableScope: () => 'global' as const,
    patchRouting: vi.fn(async () => 'ok' as const),
    openDetail: vi.fn(async () => undefined),
    loadModels: vi.fn(async () => [{ id: 'composer', label: 'Composer' }]),
  };
}

describe('WorkflowRoutingSectionComponent', () => {
  let fixture: ComponentFixture<WorkflowRoutingSectionComponent>;
  let facade: ReturnType<typeof fakeFacade>;

  beforeEach(async () => {
    facade = fakeFacade();
    await TestBed.configureTestingModule({
      imports: [WorkflowRoutingSectionComponent],
      providers: [{ provide: WorkflowsFacade, useValue: facade }],
    }).compileComponents();
    fixture = TestBed.createComponent(WorkflowRoutingSectionComponent);
    fixture.componentRef.setInput('workflow', RAW_ASSESSMENT);
    fixture.detectChanges();
  });

  it('renders routing controls for raw-mode assessment workflows', () => {
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workflow-routing-section"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="routing-stage-inspect"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="routing-default-runtime"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="routing-stage-qa-gate"]')).toBeNull();
  });

  it('shows readonly notice for bundled workflows', async () => {
    facade.writableScope = () => undefined;
    const bundled = { ...RAW_ASSESSMENT, scope: 'bundled' as const };
    fixture.componentRef.setInput('workflow', bundled);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="routing-readonly"]')).not.toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="routing-default-runtime"]')).toBeNull();
  });

  it('shows writes-disabled notice when writesEnabled is false', () => {
    fixture.componentRef.setInput('writesEnabled', false);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="routing-writes-disabled"]')).not.toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="routing-save"]')).toBeNull();
  });

  it('shows inherit model control when default runtime is cleared', () => {
    fixture.componentInstance.clearDefaults();
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="routing-default-model-inherit"]')).not.toBeNull();
  });

  it('patchRouting sends scoped routing updates', async () => {
    fixture.componentInstance.defaultsRuntime.set('cursor');
    fixture.componentInstance.defaultsModel.set('composer');
    fixture.componentInstance.markDirty();
    fixture.detectChanges();
    await fixture.componentInstance.saveRouting();
    expect(facade.patchRouting).toHaveBeenCalledWith(
      'assessment',
      'global',
      expect.objectContaining({
        sha256: 'sha-assessment',
        defaults: { runtime: 'cursor', model: 'composer' },
      }),
    );
  });

  it('saveRouting clears defaults and stage overrides when emptied', async () => {
    fixture.componentInstance.clearDefaults();
    fixture.componentInstance.clearStage('inspect');
    await fixture.componentInstance.saveRouting();
    expect(facade.patchRouting).toHaveBeenCalledWith(
      'assessment',
      'global',
      expect.objectContaining({
        defaults: { clear: true },
        stages: { inspect: { clear: true } },
      }),
    );
    expect(fixture.componentInstance.routingDirty()).toBe(false);
  });

  it('saveRouting no-ops when nothing changed', async () => {
    fixture.componentInstance.routingDirty.set(true);
    await fixture.componentInstance.saveRouting();
    expect(facade.patchRouting).not.toHaveBeenCalled();
    expect(fixture.componentInstance.routingDirty()).toBe(false);
  });

  it('saveRouting returns early without a writable scope', async () => {
    facade.writableScope = () => undefined;
    fixture.componentRef.setInput('workflow', { ...RAW_ASSESSMENT, sha256: 'sha-readonly' });
    fixture.detectChanges();
    fixture.componentInstance.defaultsRuntime.set('cursor');
    fixture.componentInstance.markDirty();
    await fixture.componentInstance.saveRouting();
    expect(facade.patchRouting).not.toHaveBeenCalled();
  });

  it('saveRouting surfaces conflict and reload reopens detail', async () => {
    facade.patchRouting = vi.fn(async () => 'conflict' as const);
    fixture.componentInstance.defaultsModel.set('opus');
    fixture.componentInstance.markDirty();
    await fixture.componentInstance.saveRouting();
    fixture.detectChanges();
    expect(fixture.componentInstance.conflict()).toBe(true);
    expect(fixture.nativeElement.querySelector('[data-testid="routing-conflict"]')).not.toBeNull();

    await fixture.componentInstance.reload();
    expect(facade.openDetail).toHaveBeenCalledWith('assessment', 'global');
    expect(fixture.componentInstance.conflict()).toBe(false);
  });

  it('saveRouting records invalid diagnostics from facade error', async () => {
    facade.patchRouting = vi.fn(async () => 'invalid' as const);
    facade.error.set('runtime not installed');
    fixture.componentInstance.setStageRuntime('inspect', 'codex');
    fixture.componentInstance.setStageModel('inspect', 'gpt');
    await fixture.componentInstance.saveRouting();
    fixture.detectChanges();
    expect(fixture.componentInstance.invalidDiagnostics()).toBe('runtime not installed');
    expect(fixture.nativeElement.querySelector('[data-testid="routing-invalid-diagnostics"]')?.textContent).toContain(
      'runtime not installed',
    );
  });

  it('stage runtime/model helpers fall back when override is missing', () => {
    fixture.componentInstance.stageOverrides.set({});
    expect(fixture.componentInstance.stageRuntime('missing')).toBe('');
    expect(fixture.componentInstance.stageModel('missing')).toBe('');
  });

  it('setStageRuntime clears model when inheriting', () => {
    fixture.componentInstance.setStageRuntime('inspect', 'claude');
    fixture.componentInstance.setStageModel('inspect', 'opus');
    fixture.componentInstance.setStageRuntime('inspect', '');
    expect(fixture.componentInstance.stageRuntime('inspect')).toBe('');
    expect(fixture.componentInstance.stageModel('inspect')).toBe('');
    expect(fixture.componentInstance.routingDirty()).toBe(true);
  });

  it('omits stage section when there are no ordinary stages', () => {
    const gateOnly: WorkflowDetail = {
      ...RAW_ASSESSMENT,
      inspect: { defaults: {}, stages: [{ id: 'gate', type: 'gate' }] },
    };
    fixture.componentRef.setInput('workflow', gateOnly);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('.stages')).toBeNull();
  });

  it('patches stage runtime/model without clearing when values are set', async () => {
    fixture.componentInstance.setStageRuntime('inspect', 'claude');
    fixture.componentInstance.setStageModel('inspect', 'opus');
    await fixture.componentInstance.saveRouting();
    expect(facade.patchRouting).toHaveBeenCalledWith(
      'assessment',
      'global',
      expect.objectContaining({
        stages: { inspect: { runtime: 'claude', model: 'opus' } },
      }),
    );
  });

  it('shows saving label while facade.saving is true', () => {
    facade.saving.set(true);
    fixture.componentInstance.markDirty();
    fixture.detectChanges();
    const save = fixture.nativeElement.querySelector('[data-testid="routing-save"]') as HTMLButtonElement;
    expect(save.disabled).toBe(true);
    expect(save.textContent).toContain('Saving');
  });

  it('coalesces undefined stage runtime/model into empty overrides on load', () => {
    const bareStages: WorkflowDetail = {
      ...RAW_ASSESSMENT,
      inspect: {
        defaults: {},
        stages: [{ id: 'inspect' }, { id: 'gate', type: 'gate' }],
      },
    };
    fixture.componentRef.setInput('workflow', bareStages);
    fixture.detectChanges();
    expect(fixture.componentInstance.stageRuntime('inspect')).toBe('');
    expect(fixture.componentInstance.stageModel('inspect')).toBe('');
    expect(fixture.componentInstance.defaultsRuntime()).toBe('');
    expect(fixture.componentInstance.defaultsModel()).toBe('');
  });

  it('setStageModel creates an override when none exists and save patches nullish empties', async () => {
    fixture.componentInstance.stageOverrides.set({});
    fixture.componentInstance.setStageModel('inspect', 'composer');
    expect(fixture.componentInstance.stageOverrides()['inspect']).toEqual({
      runtime: '',
      model: 'composer',
    });

    fixture.componentInstance.setStageRuntime('inspect', 'cursor');
    fixture.componentInstance.setStageModel('inspect', '');
    await fixture.componentInstance.saveRouting();
    expect(facade.patchRouting).toHaveBeenCalledWith(
      'assessment',
      'global',
      expect.objectContaining({
        stages: { inspect: { runtime: 'cursor', model: null } },
      }),
    );
  });

  it('saveRouting clears defaults when only model was loaded and both are emptied', async () => {
    const modelOnly: WorkflowDetail = {
      ...RAW_ASSESSMENT,
      inspect: {
        defaults: { model: 'sonnet' },
        stages: [{ id: 'inspect', runtime: 'cursor' }],
      },
    };
    fixture.componentRef.setInput('workflow', modelOnly);
    fixture.detectChanges();
    fixture.componentInstance.clearDefaults();
    fixture.componentInstance.clearStage('inspect');
    await fixture.componentInstance.saveRouting();
    expect(facade.patchRouting).toHaveBeenCalledWith(
      'assessment',
      'global',
      expect.objectContaining({
        defaults: { clear: true },
        stages: { inspect: { clear: true } },
      }),
    );
  });

  it('setStageRuntime without prior override and save null-coalesces empty fields', async () => {
    fixture.componentInstance.stageOverrides.set({});
    fixture.componentInstance.setStageRuntime('inspect', 'claude');
    expect(fixture.componentInstance.stageOverrides()['inspect']).toEqual({
      runtime: 'claude',
      model: '',
    });
    fixture.componentInstance.setStageRuntime('fresh', '');
    expect(fixture.componentInstance.stageOverrides()['fresh']).toEqual({
      runtime: '',
      model: '',
    });

    fixture.componentInstance.defaultsRuntime.set('cursor');
    fixture.componentInstance.defaultsModel.set('');
    fixture.componentInstance.setStageRuntime('inspect', 'codex');
    fixture.componentInstance.setStageModel('inspect', '');
    await fixture.componentInstance.saveRouting();
    expect(facade.patchRouting).toHaveBeenCalledWith(
      'assessment',
      'global',
      expect.objectContaining({
        defaults: { runtime: 'cursor', model: null },
        stages: { inspect: { runtime: 'codex', model: null } },
      }),
    );
  });

  it('saveRouting clears a stage when its override entry is missing', async () => {
    fixture.componentInstance.stageOverrides.set({});
    fixture.componentInstance.defaultsRuntime.set('claude');
    fixture.componentInstance.defaultsModel.set('sonnet');
    await fixture.componentInstance.saveRouting();
    expect(facade.patchRouting).toHaveBeenCalledWith(
      'assessment',
      'global',
      expect.objectContaining({
        stages: { inspect: { clear: true } },
      }),
    );
  });
});
