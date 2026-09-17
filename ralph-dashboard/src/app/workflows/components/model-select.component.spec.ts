import '../../../angular-test-env';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ModelSelectComponent } from './model-select.component';
import { WorkflowsFacade } from '../workflows.facade';

function fakeFacade(models: Array<{ id: string; label: string }> = []) {
  return { loadModels: vi.fn(async () => models) };
}

describe('ModelSelectComponent', () => {
  let fixture: ComponentFixture<ModelSelectComponent>;

  async function build(facade: ReturnType<typeof fakeFacade>) {
    await TestBed.configureTestingModule({
      imports: [ModelSelectComponent],
      providers: [{ provide: WorkflowsFacade, useValue: facade }],
    }).compileComponents();
    fixture = TestBed.createComponent(ModelSelectComponent);
  }

  it('loads models for the given runtime and falls back to an empty list on failure', async () => {
    const facade = { loadModels: vi.fn(async () => []) };
    await build(facade);
    fixture.componentRef.setInput('runtime', 'claude');
    fixture.componentRef.setInput('model', '');
    fixture.detectChanges();
    await fixture.whenStable();
    expect(facade.loadModels).toHaveBeenCalledWith('claude');
    expect(fixture.componentInstance.models()).toEqual([]);
  });

  it('does not request models when runtime is empty or "inherit"', async () => {
    const facade = fakeFacade([{ id: 'sonnet', label: 'Sonnet' }]);
    await build(facade);
    fixture.componentRef.setInput('runtime', '');
    fixture.componentRef.setInput('model', '');
    fixture.detectChanges();
    await fixture.whenStable();
    expect(facade.loadModels).not.toHaveBeenCalled();
  });

  it('selects the current model id from the loaded list', async () => {
    const facade = fakeFacade([
      { id: 'sonnet', label: 'Sonnet' },
      { id: 'opus', label: 'Opus' },
    ]);
    await build(facade);
    fixture.componentRef.setInput('runtime', 'claude');
    fixture.componentRef.setInput('model', 'opus');
    fixture.detectChanges();
    await fixture.whenStable();
    expect(fixture.componentInstance.selectValue()).toBe('opus');
    expect(fixture.componentInstance.isCustom()).toBe(false);
  });

  it('treats an unknown model id as custom and seeds the custom text box', async () => {
    const facade = fakeFacade([{ id: 'sonnet', label: 'Sonnet' }]);
    await build(facade);
    fixture.componentRef.setInput('runtime', 'claude');
    fixture.componentRef.setInput('model', 'my-custom-model');
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
    expect(fixture.componentInstance.isCustom()).toBe(true);
    expect(fixture.componentInstance.customText()).toBe('my-custom-model');
  });

  it('emits modelChange when a custom model name is typed', async () => {
    const facade = fakeFacade([{ id: 'sonnet', label: 'Sonnet' }]);
    await build(facade);
    fixture.componentRef.setInput('runtime', 'claude');
    fixture.componentRef.setInput('model', 'sonnet');
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();

    let emitted: string | null = null;
    fixture.componentInstance.modelChange.subscribe((v) => (emitted = v));
    fixture.componentInstance.onSelectValue(fixture.componentInstance.CUSTOM_SENTINEL);
    fixture.componentInstance.onCustomInput({ target: { value: 'claude-opus-4-5' } } as unknown as Event);
    expect(emitted).toBe('claude-opus-4-5');
  });

  it('ignores a slower response for a runtime that is no longer selected', async () => {
    let resolveClaude!: (models: Array<{ id: string; label: string }>) => void;
    let resolveCodex!: (models: Array<{ id: string; label: string }>) => void;
    const facade = {
      loadModels: vi.fn((runtime: string) => new Promise<Array<{ id: string; label: string }>>((resolve) => {
        if (runtime === 'claude') {
          resolveClaude = resolve;
        } else {
          resolveCodex = resolve;
        }
      })),
    };
    await build(facade);
    fixture.componentRef.setInput('runtime', 'claude');
    fixture.componentRef.setInput('model', '');
    fixture.detectChanges();
    await Promise.resolve();

    fixture.componentRef.setInput('runtime', 'codex');
    fixture.detectChanges();
    await Promise.resolve();
    resolveClaude([{ id: 'sonnet', label: 'Sonnet' }]);
    await Promise.resolve();
    expect(fixture.componentInstance.models()).toEqual([]);

    resolveCodex([{ id: 'o4-mini', label: 'o4-mini' }]);
    await Promise.resolve();
    expect(fixture.componentInstance.models()).toEqual([{ id: 'o4-mini', label: 'o4-mini' }]);
  });
});
