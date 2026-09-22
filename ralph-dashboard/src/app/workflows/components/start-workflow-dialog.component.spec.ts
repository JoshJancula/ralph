import '../../../angular-test-env';
import { provideRouter, Router } from '@angular/router';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { of } from 'rxjs';
import { StartWorkflowDialogComponent } from './start-workflow-dialog.component';
import { WorkflowsFacade } from '../workflows.facade';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { TasksSchedulesService } from '../../services/tasks-schedules.service';

function fakeFacade() {
  return {
    start: vi.fn(async () => ({ runId: 'run-123', logPath: '/tmp/x.log' })),
    loadModels: vi.fn(async () => [{ id: 'sonnet', label: 'sonnet' }, { id: 'opus', label: 'opus' }]),
    resolveWorkspaceRoot: vi.fn((path: string) => `${path}/.ralph-workspace`),
    requireProjectSelection: vi.fn(),
  };
}

function fakeWorkspaceSelector(workspaces: Array<{ path: string; projectRoot: string; label: string; exists: boolean }> = []) {
  const workspacesSignal = signal(workspaces.map((w) => ({ ...w, workspaceRoot: `${w.path}/.ralph-workspace` })));
  return {
    workspaces: workspacesSignal,
    selectedWorkspacePath: signal<string | null>(null),
    displayWorkspaces: () => workspacesSignal().map((w) => ({ path: w.path, display: w.label, exists: w.exists })),
  };
}

function fakeTasksApi() {
  return {
    listTasks: vi.fn(() => of([])),
    launchTask: vi.fn(),
  };
}

describe('StartWorkflowDialogComponent', () => {
  let fixture: ComponentFixture<StartWorkflowDialogComponent>;
  let facade: ReturnType<typeof fakeFacade>;
  let workspaceSelector: ReturnType<typeof fakeWorkspaceSelector>;
  let tasksApi: ReturnType<typeof fakeTasksApi>;

  async function build(workspaces?: Array<{ path: string; projectRoot: string; label: string; exists: boolean }>): Promise<void> {
    TestBed.resetTestingModule();
    facade = fakeFacade();
    workspaceSelector = fakeWorkspaceSelector(workspaces);
    tasksApi = fakeTasksApi();
    await TestBed.configureTestingModule({
      imports: [StartWorkflowDialogComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: facade },
        { provide: WorkspaceSelectorService, useValue: workspaceSelector },
        { provide: TasksSchedulesService, useValue: tasksApi },
      ],
    }).compileComponents();
    fixture = TestBed.createComponent(StartWorkflowDialogComponent);
    fixture.componentRef.setInput('workflowId', 'bug-fix');
    fixture.detectChanges();
  }

  beforeEach(async () => {
    await build();
  });

  it('is closed until launch() is called', () => {
    expect(fixture.nativeElement.querySelector('[data-testid="start-dialog"]')).toBeNull();
    fixture.componentInstance.launch();
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="start-dialog"]')).not.toBeNull();
  });

  it('closes on Escape and restores focus to the previous element', async () => {
    const trigger = document.createElement('button');
    trigger.textContent = 'Start';
    document.body.appendChild(trigger);
    trigger.focus();

    fixture.componentInstance.launch();
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="start-dialog"]')).not.toBeNull();

    fixture.componentInstance.onDocumentKeyDown(new KeyboardEvent('keydown', { key: 'Escape' }));
    fixture.detectChanges();
    await new Promise((r) => setTimeout(r, 0));

    expect(fixture.componentInstance.open()).toBe(false);
    expect(document.activeElement).toBe(trigger);
    trigger.remove();
  });

  it('requires a task before Review is enabled', () => {
    fixture.componentInstance.launch();
    fixture.componentInstance.source.set('adhoc');
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="start-task-error"]')).not.toBeNull();
    expect((el.querySelector('[data-testid="start-review"]') as HTMLButtonElement).disabled).toBe(true);

    fixture.componentInstance.task.set('do the thing');
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="start-task-error"]')).toBeNull();
    expect((el.querySelector('[data-testid="start-review"]') as HTMLButtonElement).disabled).toBe(false);
  });

  it('loads this workflow’s ready and backlog tasks and launches the selected queued task', async () => {
    await build([{ path: '/repo-a', projectRoot: '/repo-a', label: 'repo-a', exists: true }]);
    tasksApi.listTasks.mockReturnValue(of([
      { id: 'ready-1', title: 'Fix the release', workflowId: 'bug-fix', status: 'ready', scope: 'project', attempts: [] },
      { id: 'backlog-1', title: 'Later', workflowId: 'bug-fix', status: 'backlog', scope: 'project', attempts: [] },
      { id: 'other-1', title: 'Other workflow', workflowId: 'other', status: 'ready', scope: 'project', attempts: [] },
    ]));
    tasksApi.launchTask.mockReturnValue(of({ task: { id: 'ready-1' }, attempt: { id: 'attempt-1', status: 'launching', logPath: '' } }));

    fixture.componentInstance.launch();
    await Promise.resolve();
    fixture.detectChanges();
    expect(tasksApi.listTasks).toHaveBeenCalledWith('/repo-a/.ralph-workspace');
    expect(fixture.componentInstance.readyTasks().map((task) => task.id)).toEqual(['ready-1', 'backlog-1']);

    fixture.componentInstance.selectedTaskId.set('ready-1');
    fixture.componentInstance.confirming.set(true);
    await fixture.componentInstance.confirmStart();
    expect(tasksApi.launchTask).toHaveBeenCalledWith('ready-1', '/repo-a/.ralph-workspace', {});
    expect(facade.start).not.toHaveBeenCalled();
  });

  it('shows a resolved command preview on Review that includes runtime/model only when set', () => {
    fixture.componentInstance.launch();
    fixture.componentInstance.source.set('adhoc');
    fixture.componentInstance.task.set('do the thing');
    fixture.componentInstance.runtime.set('claude');
    fixture.componentInstance.model.set('sonnet');
    fixture.detectChanges();
    (fixture.nativeElement.querySelector('[data-testid="start-review"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    const preview = fixture.nativeElement.querySelector('[data-testid="start-command-preview"]')?.textContent;
    expect(preview).toContain('ralph workflow start bug-fix');
    expect(preview).toContain('--task');
    expect(preview).toContain('--runtime claude');
    expect(preview).toContain('--model sonnet');
  });

  it('omits --model when no runtime is set (model without runtime inherits)', () => {
    fixture.componentInstance.launch();
    fixture.componentInstance.source.set('adhoc');
    fixture.componentInstance.task.set('do the thing');
    fixture.componentInstance.model.set('sonnet');
    fixture.detectChanges();
    (fixture.nativeElement.querySelector('[data-testid="start-review"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    const preview = fixture.nativeElement.querySelector('[data-testid="start-command-preview"]')?.textContent ?? '';
    expect(preview).not.toContain('--model');
  });

  it('confirming start calls facade.start, closes the dialog, and navigates to the run', async () => {
    await build([{ path: '/repo-a', projectRoot: '/repo-a', label: 'repo-a', exists: true }]);
    const router = TestBed.inject(Router);
    const navigateSpy = vi.spyOn(router, 'navigate').mockResolvedValue(true);
    fixture.componentInstance.launch();
    fixture.componentInstance.source.set('adhoc');
    fixture.componentInstance.task.set('do the thing');
    fixture.componentInstance.confirming.set(true);
    fixture.detectChanges();
    await fixture.componentInstance.confirmStart();
    expect(facade.start).toHaveBeenCalledWith('bug-fix', { task: 'do the thing', runtime: undefined, model: undefined }, '/repo-a/.ralph-workspace');
    expect(fixture.componentInstance.open()).toBe(false);
    expect(navigateSpy).toHaveBeenCalledWith(['/workflows', 'runs', 'run-123']);
  });

  it('no workspaces registered: hides the target-workspace picker entirely', () => {
    fixture.componentInstance.launch();
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="start-workspace"]')).toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="start-workspace-hint"]')).toBeNull();
  });

  it('workspaces registered: defaults the target picker to the sidebar-selected workspace and resolves its projectRoot into the sandbox hint', async () => {
    await build([
      { path: '/repo-a', projectRoot: '/repo-a', label: 'repo-a', exists: true },
      { path: '/repo-b', projectRoot: '/repo-b', label: 'repo-b', exists: true },
    ]);
    workspaceSelector.selectedWorkspacePath.set('/repo-b');
    fixture.componentInstance.launch();
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    const select = el.querySelector('[data-testid="start-workspace"]') as HTMLSelectElement;
    expect(select).not.toBeNull();
    expect(fixture.componentInstance.targetWorkspace()).toBe('/repo-b');
    expect(el.querySelector('[data-testid="start-workspace-hint"]')?.textContent).toContain('/repo-b');

    fixture.componentInstance.targetWorkspace.set('/repo-a');
    fixture.componentInstance.source.set('adhoc');
    fixture.componentInstance.task.set('do the thing');
    fixture.componentInstance.confirming.set(true);
    fixture.detectChanges();
    await fixture.componentInstance.confirmStart();
    expect(facade.resolveWorkspaceRoot).toHaveBeenCalledWith('/repo-a');
    expect(facade.start).toHaveBeenCalledWith('bug-fix', expect.any(Object), '/repo-a/.ralph-workspace');
  });

  it('workspaces registered but none selected in the sidebar: falls back to the first known workspace', async () => {
    await build([{ path: '/repo-a', projectRoot: '/repo-a', label: 'repo-a', exists: true }]);
    fixture.componentInstance.launch();
    fixture.detectChanges();
    expect(fixture.componentInstance.targetWorkspace()).toBe('/repo-a');
  });

  it('model override is a disabled placeholder until a runtime is chosen, then becomes a model dropdown with custom entry', async () => {
    fixture.componentInstance.launch();
    fixture.componentInstance.source.set('adhoc');
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    expect(el.querySelector('ralph-model-select')).toBeNull();
    expect((el.querySelector('[data-testid="start-model"]') as HTMLInputElement).disabled).toBe(true);

    fixture.componentInstance.onRuntimeChange('claude');
    fixture.detectChanges();
    await Promise.resolve();
    await Promise.resolve();
    fixture.detectChanges();
    expect(facade.loadModels).toHaveBeenCalledWith('claude');
    const select = el.querySelector('[data-testid="workflow-model-select"]') as HTMLSelectElement;
    expect(select).not.toBeNull();
    expect(Array.from(select.options).map((o) => o.value)).toEqual(['sonnet', 'opus', '__custom__']);

    select.value = '__custom__';
    select.dispatchEvent(new Event('change'));
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="workflow-model-custom-input"]')).not.toBeNull();
  });

  it('clearing the runtime override resets the model back to inherit', async () => {
    fixture.componentInstance.launch();
    fixture.componentInstance.source.set('adhoc');
    fixture.componentInstance.onRuntimeChange('claude');
    fixture.detectChanges();
    await Promise.resolve();
    await Promise.resolve();
    fixture.componentInstance.model.set('opus');
    fixture.detectChanges();

    fixture.componentInstance.onRuntimeChange('');
    fixture.detectChanges();
    expect(fixture.componentInstance.model()).toBe('');
    expect(fixture.nativeElement.querySelector('ralph-model-select')).toBeNull();
  });

  it('Cancel closes the dialog without starting', () => {
    fixture.componentInstance.launch();
    fixture.detectChanges();
    (fixture.nativeElement.querySelector('[data-testid="start-cancel"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(fixture.componentInstance.open()).toBe(false);
    expect(facade.start).not.toHaveBeenCalled();
  });
});
