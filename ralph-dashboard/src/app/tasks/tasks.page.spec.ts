import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed, fakeAsync, tick, flush } from '@angular/core/testing';
import { signal } from '@angular/core';
import { RouterTestingModule } from '@angular/router/testing';
import { TasksPageComponent } from './tasks.page';
import { TasksSchedulesService, DashboardTask } from '../services/tasks-schedules.service';
import { TasksInventoryStore } from '../services/tasks-inventory.store';
import { WorkflowsApi } from '../workflows/workflows-api.service';
import { WorkspaceSelectorService } from '../services/workspace-selector.service';
import { ErrorDialogService } from '../services/error-dialog.service';
import type { WorkflowListItem } from '../workflows/workflow.types';
import { vi } from 'vitest';

const workflowItems: WorkflowListItem[] = [
  { id: 'wf-1', scope: 'project', effectiveScope: 'project', overview: 'One', editable: true, catalog: { purpose: 'One', mode: 'sequential', stageCount: 1, executableStageCount: 1, supervisorStageCount: 0, requiresSuppliedPlan: false, writes: false, expectedOutcome: 'o', hasHumanGates: false } },
];

function task(overrides: Partial<DashboardTask> = {}): DashboardTask {
  return {
    id: 't1',
    title: 'Task one',
    workflowId: 'wf-1',
    scope: 'project',
    status: 'backlog',
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    attempts: [],
    ...overrides,
  } as DashboardTask;
}

function expectRequest(method: string, url: string) {
  return TestBed.inject(HttpTestingController).expectOne((req) => req.method === method && req.url === url);
}

function flushInit(httpMock: HttpTestingController): void {
  httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/workflows').flush(workflowItems);
  httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/tasks').flush([]);
  httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/task-statuses').flush(['backlog']);
}

describe('TasksPageComponent', () => {
  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [TasksPageComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
      providers: [
        {
          provide: WorkspaceSelectorService,
          useValue: {
            workspaces: signal([]),
            selectedWorkspacePath: signal<string | null>(null),
            loadWorkspaces: vi.fn(),
          },
        },
        { provide: ErrorDialogService, useValue: { displayError: vi.fn().mockResolvedValue(undefined) } },
      ],
    }).compileComponents();
    TestBed.inject(TasksInventoryStore).reset();
  });

  afterEach(() => {
    TestBed.inject(HttpTestingController).verify();
  });

  it('loads tasks, workflows, and statuses on init', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();

    expectRequest('GET', '/api/workflows').flush(workflowItems);
    expectRequest('GET', '/api/tasks').flush([task()]);
    expectRequest('GET', '/api/task-statuses').flush(['backlog', 'ready']);

    tick();
    fixture.detectChanges();

    expect(fixture.componentInstance.tasks().length).toBe(1);
    expect(fixture.componentInstance.workflows()).toEqual(workflowItems);
    expect(fixture.componentInstance.statuses()).toEqual(['backlog', 'ready']);
    expect(fixture.componentInstance.workflowLoading()).toBe(false);
    flush();
  }));

  it('shows empty state when no tasks exist', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();

    expectRequest('GET', '/api/workflows').flush(workflowItems);
    expectRequest('GET', '/api/tasks').flush([]);
    expectRequest('GET', '/api/task-statuses').flush([]);

    tick();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="tasks-empty"]')).not.toBeNull();
    flush();
  }));

  it('defaults to the active-board task view', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();

    expectRequest('GET', '/api/workflows').flush(workflowItems);
    expectRequest('GET', '/api/tasks').flush([task({ status: 'ready' })]);
    expectRequest('GET', '/api/task-statuses').flush(['backlog', 'ready']);
    tick();
    fixture.detectChanges();

    expect(fixture.componentInstance.taskView()).toBe('active-board');
    expect(fixture.nativeElement.querySelector('[aria-label="Task board"]')).not.toBeNull();
    fixture.componentInstance.view.set('list');
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[aria-label="Task list"]')).not.toBeNull();
    flush();
  }));

  it('separates active work, backlog, and history', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();

    expectRequest('GET', '/api/workflows').flush(workflowItems);
    expectRequest('GET', '/api/tasks').flush([
      task(),
      task({ id: 't2', status: 'ready' }),
      task({ id: 't3', status: 'completed' }),
    ]);
    expectRequest('GET', '/api/task-statuses').flush(['backlog', 'ready', 'completed']);
    tick();
    fixture.detectChanges();

    expect(fixture.componentInstance.items('backlog').length).toBe(0);
    expect(fixture.componentInstance.items('ready').length).toBe(1);
    fixture.componentInstance.taskView.set('backlog');
    expect(fixture.componentInstance.visibleTasks().map((item) => item.id)).toEqual(['t1']);
    fixture.componentInstance.taskView.set('history');
    expect(fixture.componentInstance.visibleTasks().map((item) => item.id)).toEqual(['t3']);
    flush();
  }));

  it('opens the editor when a task list row is clicked in every task view', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();

    for (const [view, status] of [
      ['active-board', 'ready'],
      ['backlog', 'backlog'],
      ['history', 'completed'],
    ] as const) {
      fixture.componentInstance.taskView.set(view);
      fixture.componentInstance.view.set('list');
      fixture.componentInstance.tasks.set([task({ id: view, status })]);
      fixture.detectChanges();
      (fixture.nativeElement.querySelector('.list-row') as HTMLElement).click();

      expect(fixture.componentInstance.open()).toBe(true);
      expect(fixture.componentInstance.editingId()).toBe(view);
      fixture.componentInstance.close();
    }
    flush();
  }));

  it('lastAttempt returns the most recent attempt', () => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    const t = task({ attempts: [{ id: 'a1', status: 'running', logPath: '' }, { id: 'a2', status: 'blocked', logPath: '', outcome: 'blocked' }] });
    expect(fixture.componentInstance.lastAttempt(t)?.id).toBe('a2');
  });

  it('target formats new-project mode', () => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    const t = task({ targetMode: 'new-project', projectPath: '/tmp/proj' });
    expect(fixture.componentInstance.target(t)).toBe('New: /tmp/proj');
  });

  it('target formats global mode', () => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    const t = task({ targetMode: 'global' });
    expect(fixture.componentInstance.target(t)).toBe('Global setup');
  });

  it('target falls back to current project when workspace is unknown', () => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    const t = task({ targetMode: 'registered' });
    expect(fixture.componentInstance.target(t)).toBe('Current project');
  });

  it('create opens modal with sensible defaults', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();
    expectRequest('GET', '/api/workflows').flush(workflowItems);
    expectRequest('GET', '/api/tasks').flush([]);
    expectRequest('GET', '/api/task-statuses').flush(['backlog']);
    tick();

    fixture.componentInstance.create();
    expect(fixture.componentInstance.open()).toBe(true);
    expect(fixture.componentInstance.editingId()).toBeNull();
    expect(fixture.componentInstance.model.workflowId).toBe('wf-1');
    expect(fixture.componentInstance.model.status).toBe('backlog');
    flush();
  }));

  it('edit opens modal with task values', () => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    const t = task({ targetMode: 'global', targetWorkspaceRoot: '/tmp/ws' });
    fixture.componentInstance.edit(t);
    expect(fixture.componentInstance.open()).toBe(true);
    expect(fixture.componentInstance.editingId()).toBe('t1');
    expect(fixture.componentInstance.model.targetMode).toBe('global');
  });

  it('save creates a new task', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    fixture.componentInstance.model = { ...fixture.componentInstance.model, title: 'New', workflowId: 'wf-1', status: 'backlog' };
    fixture.componentInstance.save();

    const req = expectRequest('POST', '/api/tasks');
    expect(req.request.body.title).toBe('New');
    req.flush(task({ title: 'New' }));
    tick();
    expectRequest('GET', '/api/tasks').flush([]);
    expectRequest('GET', '/api/task-statuses').flush(['backlog']);
    tick();
    expect(fixture.componentInstance.open()).toBe(false);
    flush();
  }));

  it('save patches an existing task', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    fixture.componentInstance.editingId.set('t1');
    fixture.componentInstance.model = { ...fixture.componentInstance.model, title: 'Updated', workflowId: 'wf-1' };
    fixture.componentInstance.save();

    const req = expectRequest('PATCH', '/api/tasks/t1');
    expect(req.request.body.title).toBe('Updated');
    req.flush(task({ title: 'Updated' }));
    tick();
    expectRequest('GET', '/api/tasks').flush([]);
    expectRequest('GET', '/api/task-statuses').flush(['backlog']);
    tick();
    flush();
  }));

  it('move updates task status', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    const t = task();
    fixture.componentInstance.move(t, 'ready');

    const req = expectRequest('PATCH', '/api/tasks/t1');
    expect(req.request.body).toEqual({ status: 'ready' });
    req.flush(task({ status: 'ready' }));
    tick();
    expectRequest('GET', '/api/tasks').flush([]);
    expectRequest('GET', '/api/task-statuses').flush(['backlog']);
    tick();
    flush();
  }));

  it('moves a card between board columns when it is dropped', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();
    const httpMock = TestBed.inject(HttpTestingController);
    httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/workflows').flush(workflowItems);
    httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/tasks').flush([task({ status: 'ready' })]);
    httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/task-statuses').flush(['ready', 'in_progress']);
    tick();

    const dragged = task({ status: 'ready' });
    fixture.componentInstance.onDragStart({ dataTransfer: { setData: vi.fn(), effectAllowed: '' } } as unknown as DragEvent, dragged);
    fixture.componentInstance.onDrop({ preventDefault: vi.fn() } as unknown as DragEvent, 'in_progress');
    const req = expectRequest('PATCH', '/api/tasks/t1');
    expect(req.request.body).toEqual({ status: 'in_progress' });
    req.flush(task({ status: 'in_progress' }));
    tick();
    expectRequest('GET', '/api/tasks').flush([]);
    expectRequest('GET', '/api/task-statuses').flush(['ready', 'in_progress']);
    tick();
    flush();
  }));

  it('runs a ready task now through its durable task launch endpoint', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();

    fixture.componentInstance.runNow(task({ status: 'ready' }));
    const req = expectRequest('POST', '/api/tasks/t1/launch');
    expect(req.request.body).toEqual({});
    req.flush({ task: task({ status: 'in_progress' }), attempt: { id: 'attempt-1', status: 'launching', logPath: '' } });
    tick();
    expectRequest('GET', '/api/tasks').flush([]);
    expectRequest('GET', '/api/task-statuses').flush(['backlog']);
    tick();
    flush();
  }));

  it('add appends a new status and persists', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    fixture.componentInstance.statuses.set(['backlog']);
    fixture.componentInstance.newStatus = 'review';
    fixture.componentInstance.add();

    const req = expectRequest('PUT', '/api/task-statuses');
    expect(req.request.body).toEqual({ statuses: ['backlog', 'review'] });
    req.flush(['backlog', 'review']);
    tick();
    expect(fixture.componentInstance.statuses()).toEqual(['backlog', 'review']);
    flush();
  }));

  it('remove deletes a status and persists', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    fixture.componentInstance.statuses.set(['backlog', 'review']);
    fixture.componentInstance.remove('review');

    const req = expectRequest('PUT', '/api/task-statuses');
    expect(req.request.body).toEqual({ statuses: ['backlog'] });
    req.flush(['backlog']);
    tick();
    expect(fixture.componentInstance.statuses()).toEqual(['backlog']);
    flush();
  }));

  it('does not show the route skeleton when inventory was loaded earlier', fakeAsync(() => {
    const first = TestBed.createComponent(TasksPageComponent);
    first.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    first.destroy();

    const second = TestBed.createComponent(TasksPageComponent);
    second.detectChanges();
    expect(second.componentInstance.showLoadingSkeleton()).toBe(false);
    expect(second.componentInstance.tasks().length).toBe(0);

    expectRequest('GET', '/api/workflows').flush(workflowItems);
    expectRequest('GET', '/api/tasks').flush([task()]);
    expectRequest('GET', '/api/task-statuses').flush(['backlog']);
    tick();
    flush();
  }));

  it('load falls back to default statuses on error', fakeAsync(() => {
    const fixture = TestBed.createComponent(TasksPageComponent);
    fixture.detectChanges();
    // ngOnInit already issued three requests; flush the workflows one and error the rest.
    TestBed.inject(HttpTestingController).expectOne((req) => req.method === 'GET' && req.url === '/api/workflows').flush(workflowItems);
    expectRequest('GET', '/api/tasks').flush('error', { status: 500, statusText: 'Error' });
    expectRequest('GET', '/api/task-statuses').flush('error', { status: 500, statusText: 'Error' });

    tick();
    expect(fixture.componentInstance.error()).toBeTruthy();
    expect(fixture.componentInstance.statuses()).toEqual(['backlog', 'ready', 'in_progress', 'review', 'blocked', 'completed', 'discarded']);
    flush();
  }));
});
