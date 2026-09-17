import '../../angular-test-env';
import { provideRouter, ActivatedRoute, convertToParamMap } from '@angular/router';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { of } from 'rxjs';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { WorkflowDetailPageComponent } from './workflow-detail.page';
import { WorkflowsFacade } from './workflows.facade';
import type { WorkflowDetail } from './workflow.types';

const DETAIL: WorkflowDetail = {
  id: 'bug-fix',
  scope: 'bundled',
  raw: '---\nname: bug-fix\n---\n',
  sha256: 'x',
  inspect: {},
  mermaid: '',
  unsupportedKeys: [],
};

function fakeFacade() {
  return {
    openDetail: vi.fn(async () => undefined),
    stopRunsPolling: vi.fn(),
    selected: signal<WorkflowDetail | null>(null),
    error: signal<string | null>(null),
    saving: signal(false),
    needsProjectSelection: signal(false),
    customize: vi.fn(async () => null),
    remove: vi.fn(async () => true),
    writableScope: () => undefined,
    runtimes: signal([]),
    loadModels: vi.fn(async () => []),
    isTriggering: () => false,
    start: vi.fn(async () => null),
    runs: () => [],
    runsLoading: () => false,
  };
}

describe('WorkflowDetailPageComponent', () => {
  it('loads the workflow named by the :id route param', async () => {
    const facade = fakeFacade();
    await TestBed.configureTestingModule({
      imports: [WorkflowDetailPageComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: facade },
        {
          provide: ActivatedRoute,
          useValue: { paramMap: of(convertToParamMap({ id: 'bug-fix' })), queryParamMap: of(convertToParamMap({})) },
        },
      ],
    }).compileComponents();
    const fixture: ComponentFixture<WorkflowDetailPageComponent> = TestBed.createComponent(WorkflowDetailPageComponent);
    fixture.detectChanges();
    expect(facade.openDetail).toHaveBeenCalledWith('bug-fix', undefined);
  });

  it('does nothing when the :id route param is absent', async () => {
    const facade = fakeFacade();
    await TestBed.configureTestingModule({
      imports: [WorkflowDetailPageComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: facade },
        {
          provide: ActivatedRoute,
          useValue: { paramMap: of(convertToParamMap({})), queryParamMap: of(convertToParamMap({})) },
        },
      ],
    }).compileComponents();
    const fixture: ComponentFixture<WorkflowDetailPageComponent> = TestBed.createComponent(WorkflowDetailPageComponent);
    fixture.detectChanges();
    expect(facade.openDetail).not.toHaveBeenCalled();
  });

  it('shows a loading message until facade.selected() resolves, then renders the detail', async () => {
    const facade = fakeFacade();
    await TestBed.configureTestingModule({
      imports: [WorkflowDetailPageComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: facade },
        {
          provide: ActivatedRoute,
          useValue: { paramMap: of(convertToParamMap({ id: 'bug-fix' })), queryParamMap: of(convertToParamMap({})) },
        },
      ],
    }).compileComponents();
    const fixture: ComponentFixture<WorkflowDetailPageComponent> = TestBed.createComponent(WorkflowDetailPageComponent);
    fixture.detectChanges();
    expect(fixture.nativeElement.textContent).toContain('Loading workflow');

    facade.selected.set(DETAIL);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="workflow-detail"]')).not.toBeNull();
  });

  it('shows an error message instead of the loading state when facade.error() is set', async () => {
    const facade = fakeFacade();
    facade.error.set('Workflow not found');
    await TestBed.configureTestingModule({
      imports: [WorkflowDetailPageComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: facade },
        {
          provide: ActivatedRoute,
          useValue: { paramMap: of(convertToParamMap({ id: 'missing' })), queryParamMap: of(convertToParamMap({})) },
        },
      ],
    }).compileComponents();
    const fixture: ComponentFixture<WorkflowDetailPageComponent> = TestBed.createComponent(WorkflowDetailPageComponent);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="workflow-detail-error"]')?.textContent).toContain('Workflow not found');
    expect(fixture.nativeElement.textContent).not.toContain('Loading workflow');
  });
});
