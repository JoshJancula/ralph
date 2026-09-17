import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed, fakeAsync, tick, flush } from '@angular/core/testing';
import { signal } from '@angular/core';
import { RouterTestingModule } from '@angular/router/testing';
import { SchedulesPageComponent } from './schedules.page';
import { TasksSchedulesService, DashboardSchedule } from '../services/tasks-schedules.service';
import { WorkflowsApi } from '../workflows/workflows-api.service';
import type { WorkflowListItem } from '../workflows/workflow.types';
import { ErrorDialogService } from '../services/error-dialog.service';
import { vi } from 'vitest';

const workflowItems: WorkflowListItem[] = [
  { id: 'wf-1', scope: 'project', effectiveScope: 'project', overview: 'One', editable: true, catalog: { purpose: 'One', mode: 'sequential', stageCount: 1, executableStageCount: 1, supervisorStageCount: 0, requiresSuppliedPlan: false, writes: false, expectedOutcome: 'o', hasHumanGates: false } },
];

function schedule(overrides: Partial<DashboardSchedule> = {}): DashboardSchedule {
  return {
    id: 'sched-1',
    name: 'Daily',
    workflowId: 'wf-1',
    cron: '0 9 * * *',
    timezone: 'UTC',
    enabled: true,
    ...overrides,
  } as DashboardSchedule;
}

function expectRequest(method: string, url: string) {
  return TestBed.inject(HttpTestingController).expectOne((req) => req.method === method && req.url === url);
}

function flushInit(httpMock: HttpTestingController): void {
  httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/schedules').flush([]);
  httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/workflows').flush(workflowItems);
  httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/task-statuses').flush(['ready', 'in_progress']);
}

describe('SchedulesPageComponent', () => {
  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [SchedulesPageComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
      providers: [
        { provide: ErrorDialogService, useValue: { displayError: vi.fn().mockResolvedValue(undefined) } },
      ],
    }).compileComponents();
  });

  afterEach(() => {
    TestBed.inject(HttpTestingController).verify();
  });

  it('loads schedules, workflows, and statuses on init', fakeAsync(() => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.detectChanges();

    expectRequest('GET', '/api/schedules').flush([schedule()]);
    expectRequest('GET', '/api/workflows').flush(workflowItems);
    expectRequest('GET', '/api/task-statuses').flush(['ready', 'in_progress']);

    tick();
    fixture.detectChanges();

    expect(fixture.componentInstance.schedules().length).toBe(1);
    expect(fixture.componentInstance.workflows()).toEqual(workflowItems);
    expect(fixture.componentInstance.statuses()).toEqual(['ready', 'in_progress']);
    expect(fixture.nativeElement.textContent).toContain('Daily');
    flush();
  }));

  it('shows empty state when no schedules exist', fakeAsync(() => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.detectChanges();

    expectRequest('GET', '/api/schedules').flush([]);
    expectRequest('GET', '/api/workflows').flush([]);
    expectRequest('GET', '/api/task-statuses').flush([]);

    tick();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="schedules-empty"]')).not.toBeNull();
    flush();
  }));

  it('labels a workflow schedule correctly', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    const s = schedule({ worker: undefined, workflowId: 'wf-1' });
    expect(fixture.componentInstance.kindLabel(s)).toBe('Workflow');
    expect(fixture.componentInstance.sourceLabel(s)).toBe('wf-1');
  });

  it('labels a one-at-a-time task worker', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    const s = schedule({ worker: { mode: 'one', maxConcurrent: 1, status: 'ready' }, workflowId: undefined });
    expect(fixture.componentInstance.kindLabel(s)).toBe('Task worker, one at a time');
    expect(fixture.componentInstance.sourceLabel(s)).toBe('Tasks in ready');
  });

  it('labels an all-mode task worker with concurrency', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    const s = schedule({ worker: { mode: 'all', maxConcurrent: 4, status: 'in_progress' }, workflowId: undefined });
    expect(fixture.componentInstance.kindLabel(s)).toBe('Task worker, up to 4 at once');
  });

  it('runningCount returns active task ids for workers', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    const s = schedule({ worker: { mode: 'one', maxConcurrent: 1, status: 'ready' }, activeTaskIds: ['t1', 't2'] });
    expect(fixture.componentInstance.runningCount(s)).toBe(2);
    expect(fixture.componentInstance.runningLabel(s)).toBe('2 tasks running');
  });

  it('runningCount returns 1 for a launching or running workflow attempt', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    const running = schedule({ activeAttempt: { id: 'a1', status: 'running', logPath: '' } });
    expect(fixture.componentInstance.runningCount(running)).toBe(1);
    expect(fixture.componentInstance.runningLabel(running)).toBe('Run in progress');
  });

  it('atLimit is true when a workflow run is active', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    const running = schedule({ activeAttempt: { id: 'a1', status: 'running', logPath: '' } });
    expect(fixture.componentInstance.atLimit(running)).toBe(true);
  });

  it('atLimit respects one-mode worker limit', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    const s = schedule({ worker: { mode: 'one', maxConcurrent: 1, status: 'ready' }, activeTaskIds: ['t1'] });
    expect(fixture.componentInstance.atLimit(s)).toBe(true);
  });

  it('atLimit respects all-mode worker concurrency', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    const s = schedule({ worker: { mode: 'all', maxConcurrent: 3, status: 'ready' }, activeTaskIds: ['t1', 't2', 't3'] });
    expect(fixture.componentInstance.atLimit(s)).toBe(true);
  });

  it('canSave requires a workflow brief for non-worker schedules', fakeAsync(() => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    fixture.componentInstance.draft = { ...fixture.componentInstance.draft, runs: 'wf-1', brief: '' };
    expect(fixture.componentInstance.canSave()).toBe(false);
    fixture.componentInstance.draft.brief = 'do thing';
    expect(fixture.componentInstance.canSave()).toBe(true);
    flush();
  }));

  it('canSave requires a non-reserved status for task workers', fakeAsync(() => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    fixture.componentInstance.draft = { ...fixture.componentInstance.draft, runs: '__task-worker__', status: 'ready' };
    expect(fixture.componentInstance.canSave()).toBe(true);
    fixture.componentInstance.draft.status = 'completed';
    expect(fixture.componentInstance.canSave()).toBe(false);
    flush();
  }));

  it('openCreate resets draft and opens modal', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.componentInstance.openCreate();
    expect(fixture.componentInstance.editing()).toBe(true);
    expect(fixture.componentInstance.editingId()).toBeNull();
    expect(fixture.componentInstance.draft.name).toBe('');
  });

  it('openEdit populates draft from existing schedule', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    const s = schedule({ worker: { mode: 'all', maxConcurrent: 5, status: 'ready' }, brief: 'brief text' });
    fixture.componentInstance.openEdit(s);
    expect(fixture.componentInstance.editingId()).toBe('sched-1');
    expect(fixture.componentInstance.draft.mode).toBe('all');
    expect(fixture.componentInstance.draft.maxConcurrent).toBe(5);
    expect(fixture.componentInstance.draft.brief).toBe('brief text');
  });

  it('applyPreset copies preset cron when not custom', () => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.componentInstance.draft.preset = '0 9 * * *';
    fixture.componentInstance.applyPreset();
    expect(fixture.componentInstance.draft.cron).toBe('0 9 * * *');
  });

  it('preview fetches next run times', fakeAsync(() => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    fixture.componentInstance.draft.cron = '0 9 * * *';
    fixture.componentInstance.draft.timezone = 'UTC';
    fixture.componentInstance.preview();
    expectRequest('POST', '/api/schedules/preview').flush({ times: ['09:00'] });
    tick();
    expect(fixture.componentInstance.previewTimes()).toEqual(['09:00']);
    flush();
  }));

  it('save creates a new schedule', fakeAsync(() => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    fixture.componentInstance.draft = { ...fixture.componentInstance.draft, runs: 'wf-1', name: 'New', brief: 'brief', cron: '0 9 * * *', timezone: 'UTC', enabled: true };
    fixture.componentInstance.save();

    const req = expectRequest('POST', '/api/schedules');
    expect(req.request.body.worker).toBeNull();
    expect(req.request.body.workflowId).toBe('wf-1');
    req.flush(schedule());
    tick();
    expectRequest('GET', '/api/schedules').flush([]);
    tick();
    expect(fixture.componentInstance.editing()).toBe(false);
    flush();
  }));

  it('save patches an existing task worker schedule', fakeAsync(() => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    fixture.componentInstance.editingId.set('sched-1');
    fixture.componentInstance.draft = { ...fixture.componentInstance.draft, runs: '__task-worker__', name: 'Worker', status: 'ready', mode: 'one', maxConcurrent: 1, cron: '0 9 * * *', timezone: 'UTC', enabled: true };
    fixture.componentInstance.save();

    const req = expectRequest('PATCH', '/api/schedules/sched-1');
    expect(req.request.body.worker).toEqual({ mode: 'one', maxConcurrent: 1, status: 'ready' });
    req.flush(schedule());
    tick();
    expectRequest('GET', '/api/schedules').flush([]);
    tick();
    flush();
  }));

  it('toggle enables or disables a schedule', fakeAsync(() => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    const s = schedule({ enabled: true });
    fixture.componentInstance.toggle(s);

    const req = expectRequest('PATCH', '/api/schedules/sched-1');
    expect(req.request.body).toEqual({ enabled: false });
    req.flush(schedule({ enabled: false }));
    tick();
    expectRequest('GET', '/api/schedules').flush([]);
    tick();
    flush();
  }));

  it('run triggers a schedule and surfaces errors', fakeAsync(() => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.detectChanges();
    flushInit(TestBed.inject(HttpTestingController));
    tick();
    const s = schedule();
    fixture.componentInstance.run(s);

    const req = expectRequest('POST', '/api/schedules/sched-1/run');
    req.flush({}, { status: 409, statusText: 'Conflict' });
    tick();
    expectRequest('GET', '/api/schedules').flush([]);
    tick();
    expect(fixture.componentInstance.notice()).toContain('Unable to run schedule');
    flush();
  }));

  it('load surfaces an error when schedules fail', fakeAsync(() => {
    const fixture = TestBed.createComponent(SchedulesPageComponent);
    fixture.detectChanges();
    // The initial ngOnInit load() issues three requests; flush schedules with an error.
    expectRequest('GET', '/api/schedules').flush('error', { status: 500, statusText: 'Error' });
    TestBed.inject(HttpTestingController).expectOne({ method: 'GET', url: '/api/workflows' }).flush(workflowItems);
    TestBed.inject(HttpTestingController).expectOne({ method: 'GET', url: '/api/task-statuses' }).flush(['ready']);
    tick();
    expect(fixture.componentInstance.error()).toBeTruthy();
    expect(fixture.componentInstance.loading()).toBe(false);
    flush();
  }));
});
