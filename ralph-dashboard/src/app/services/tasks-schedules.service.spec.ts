import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { TasksSchedulesService, DashboardTask, DashboardSchedule } from './tasks-schedules.service';

describe('TasksSchedulesService', () => {
  let service: TasksSchedulesService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [TasksSchedulesService],
    });
    service = TestBed.inject(TasksSchedulesService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  function expectRequest(method: string, url: string) {
    return httpMock.expectOne((req) => req.method === method && req.url === url);
  }

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  it('lists tasks via GET /api/tasks', () => {
    service.listTasks().subscribe((tasks) => {
      expect(tasks).toEqual([{ id: 't1' } as DashboardTask]);
    });
    const req = expectRequest('GET', '/api/tasks');
    req.flush([{ id: 't1' }]);
  });

  it('scopes task reads and launches to an explicitly selected workspace', () => {
    service.listTasks('/workspaces/a').subscribe();
    const list = httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/tasks' && req.params.get('workspaceRoot') === '/workspaces/a');
    list.flush([]);

    service.launchTask('task-1', '/workspaces/a').subscribe();
    const launch = httpMock.expectOne((req) => req.method === 'POST' && req.url === '/api/tasks/task-1/launch' && req.params.get('workspaceRoot') === '/workspaces/a');
    launch.flush({ task: { id: 'task-1' }, attempt: {} });
  });

  it('lists task statuses via GET /api/task-statuses', () => {
    service.listTaskStatuses().subscribe((statuses) => {
      expect(statuses).toEqual(['todo', 'done']);
    });
    expectRequest('GET', '/api/task-statuses').flush(['todo', 'done']);
  });

  it('saves task statuses via PUT /api/task-statuses', () => {
    service.saveTaskStatuses(['todo', 'done']).subscribe((statuses) => {
      expect(statuses).toEqual(['todo', 'done']);
    });
    const req = expectRequest('PUT', '/api/task-statuses');
    expect(req.request.body).toEqual({ statuses: ['todo', 'done'] });
    req.flush(['todo', 'done']);
  });

  it('creates a task via POST /api/tasks', () => {
    const body: Partial<DashboardTask> = { title: 'New task' };
    service.createTask(body).subscribe((task) => {
      expect(task.title).toBe('New task');
    });
    const req = expectRequest('POST', '/api/tasks');
    expect(req.request.body).toBe(body);
    req.flush({ id: 't2', title: 'New task' } as DashboardTask);
  });

  it('patches a task via PATCH /api/tasks/:id', () => {
    service.patchTask('task-1', { status: 'done' }).subscribe((task) => {
      expect(task.status).toBe('done');
    });
    const req = expectRequest('PATCH', '/api/tasks/task-1');
    expect(req.request.body).toEqual({ status: 'done' });
    req.flush({ id: 'task-1', status: 'done' } as DashboardTask);
  });

  it('encodes task ids in patch URLs', () => {
    service.patchTask('task/with#special', {}).subscribe();
    const req = httpMock.expectOne((r) => r.url === '/api/tasks/task%2Fwith%23special');
    req.flush({ id: 'task/with#special' } as DashboardTask);
  });

  it('launches a task via POST /api/tasks/:id/launch', () => {
    service.launchTask('task-1').subscribe((result) => {
      expect(result.task.id).toBe('task-1');
    });
    const req = expectRequest('POST', '/api/tasks/task-1/launch');
    expect(req.request.body).toEqual({});
    req.flush({ task: { id: 'task-1' }, attempt: {} });
  });

  it('launches with runtime-only override and runtime+model together', () => {
    service.launchTask('task-1', undefined, { runtime: 'cursor' }).subscribe();
    const runtimeOnly = expectRequest('POST', '/api/tasks/task-1/launch');
    expect(runtimeOnly.request.body).toEqual({ runtime: 'cursor' });
    runtimeOnly.flush({ task: { id: 'task-1' }, attempt: {} });

    service.launchTask('task-1', '/ws', { runtime: 'claude', model: 'sonnet' }).subscribe();
    const both = httpMock.expectOne(
      (req) =>
        req.method === 'POST' &&
        req.url === '/api/tasks/task-1/launch' &&
        req.params.get('workspaceRoot') === '/ws',
    );
    expect(both.request.body).toEqual({ runtime: 'claude', model: 'sonnet' });
    both.flush({ task: { id: 'task-1' }, attempt: {} });
  });

  it('does not send model when runtime override is absent', () => {
    service.launchTask('task-1', undefined, { model: 'sonnet' }).subscribe();
    const req = expectRequest('POST', '/api/tasks/task-1/launch');
    expect(req.request.body).toEqual({});
    req.flush({ task: { id: 'task-1' }, attempt: {} });
  });

  it('creates and patches tasks with workspaceRoot query params', () => {
    service.createTask({ title: 'Scoped' }, '/ws').subscribe();
    const create = httpMock.expectOne(
      (req) => req.method === 'POST' && req.url === '/api/tasks' && req.params.get('workspaceRoot') === '/ws',
    );
    create.flush({ id: 't3', title: 'Scoped' } as DashboardTask);

    service.patchTask('t3', { status: 'done' }, '/ws').subscribe();
    const patch = httpMock.expectOne(
      (req) =>
        req.method === 'PATCH' &&
        req.url === '/api/tasks/t3' &&
        req.params.get('workspaceRoot') === '/ws',
    );
    patch.flush({ id: 't3', status: 'done' } as DashboardTask);
  });

  it('covers leaf-plan read/write/launch/cancel endpoints', () => {
    service.launchLeafPlan('task-1', '/ws').subscribe();
    httpMock
      .expectOne(
        (req) =>
          req.method === 'POST' &&
          req.url === '/api/tasks/task-1/launch-leaf-plan' &&
          req.params.get('workspaceRoot') === '/ws',
      )
      .flush({ task: { id: 'task-1' }, attempt: {} });

    service.getLeafPlan('task-1').subscribe();
    httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/tasks/task-1/leaf-plan').flush({
      path: 'a.md',
      title: 'A',
      updatedAt: 'now',
      content: '# A',
    });

    service.saveLeafPlan('task-1', { title: 'A', content: '# A' }, '/ws').subscribe();
    httpMock
      .expectOne(
        (req) =>
          req.method === 'PUT' &&
          req.url === '/api/tasks/task-1/leaf-plan' &&
          req.params.get('workspaceRoot') === '/ws',
      )
      .flush({ id: 'task-1' } as DashboardTask);

    service.cancelLeafPlan('attempt-1', '/ws').subscribe();
    httpMock
      .expectOne(
        (req) =>
          req.method === 'POST' &&
          req.url === '/api/leaf-runs/attempt-1/cancel' &&
          req.params.get('workspaceRoot') === '/ws',
      )
      .flush({ ok: true });
  });

  it('lists schedules via GET /api/schedules', () => {
    service.listSchedules().subscribe((schedules) => {
      expect(schedules).toEqual([{ id: 's1' } as DashboardSchedule]);
    });
    expectRequest('GET', '/api/schedules').flush([{ id: 's1' }]);
  });

  it('creates a schedule via POST /api/schedules', () => {
    const body: Partial<DashboardSchedule> = { name: 'Daily' };
    service.createSchedule(body).subscribe((schedule) => {
      expect(schedule.name).toBe('Daily');
    });
    const req = expectRequest('POST', '/api/schedules');
    expect(req.request.body).toBe(body);
    req.flush({ id: 's2', name: 'Daily' } as DashboardSchedule);
  });

  it('patches a schedule via PATCH /api/schedules/:id', () => {
    service.patchSchedule('sched-1', { enabled: true }).subscribe((schedule) => {
      expect(schedule.enabled).toBe(true);
    });
    const req = expectRequest('PATCH', '/api/schedules/sched-1');
    expect(req.request.body).toEqual({ enabled: true });
    req.flush({ id: 'sched-1', enabled: true } as DashboardSchedule);
  });

  it('encodes schedule ids in patch URLs', () => {
    service.patchSchedule('sched/with#special', {}).subscribe();
    const req = httpMock.expectOne((r) => r.url === '/api/schedules/sched%2Fwith%23special');
    req.flush({ id: 'sched/with#special' } as DashboardSchedule);
  });

  it('previews a cron schedule via POST /api/schedules/preview', () => {
    service.preview('0 9 * * *', 'UTC').subscribe((result) => {
      expect(result.times).toEqual(['09:00']);
    });
    const req = expectRequest('POST', '/api/schedules/preview');
    expect(req.request.body).toEqual({ cron: '0 9 * * *', timezone: 'UTC' });
    req.flush({ times: ['09:00'] });
  });

  it('runs a schedule via POST /api/schedules/:id/run', () => {
    service.runSchedule('sched-1').subscribe((schedule) => {
      expect(schedule.id).toBe('sched-1');
    });
    const req = expectRequest('POST', '/api/schedules/sched-1/run');
    req.flush({ id: 'sched-1' } as DashboardSchedule);
  });

  it('lists dashboard templates via GET /api/dashboard-templates', () => {
    service.templates().subscribe((templates) => {
      expect(templates).toEqual([{ id: 'tpl-1', category: 'c', purpose: 'p', outputs: 'o', stageCount: 1, safety: 's', installable: true }]);
    });
    expectRequest('GET', '/api/dashboard-templates').flush([
      { id: 'tpl-1', category: 'c', purpose: 'p', outputs: 'o', stageCount: 1, safety: 's', installable: true },
    ]);
  });

  it('installs a template via POST /api/dashboard-templates/:id/install with project scope', () => {
    service.installTemplate('tpl-1').subscribe();
    const req = expectRequest('POST', '/api/dashboard-templates/tpl-1/install');
    expect(req.request.body).toEqual({ scope: 'project' });
    req.flush({});
  });

  it('installs a template with explicit global scope', () => {
    service.installTemplate('tpl-1', 'global').subscribe();
    const req = expectRequest('POST', '/api/dashboard-templates/tpl-1/install');
    expect(req.request.body).toEqual({ scope: 'global' });
    req.flush({});
  });
});
