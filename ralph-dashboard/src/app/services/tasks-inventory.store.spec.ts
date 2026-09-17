import '../../angular-test-env';
import { TestBed, fakeAsync, tick, flush } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TasksInventoryStore } from './tasks-inventory.store';
import type { DashboardTask } from './tasks-schedules.service';

function task(id: string): DashboardTask {
  return {
    id,
    title: `Task ${id}`,
    workflowId: 'wf-1',
    scope: 'project',
    status: 'backlog',
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    attempts: [],
  };
}

describe('TasksInventoryStore', () => {
  let store: TasksInventoryStore;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
    });
    store = TestBed.inject(TasksInventoryStore);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('keeps showing cached tasks on refresh without toggling the route skeleton', fakeAsync(() => {
    store.refresh();
    const tasksReq = httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/tasks');
    const statusesReq = httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/task-statuses');
    tasksReq.flush([task('t1')]);
    statusesReq.flush(['backlog']);
    tick();

    expect(store.hasLoadedOnce()).toBe(true);
    expect(store.tasks().map((item) => item.id)).toEqual(['t1']);

    store.refresh();
    expect(store.loading()).toBe(false);
    expect(store.tasks().map((item) => item.id)).toEqual(['t1']);

    const tasksReq2 = httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/tasks');
    const statusesReq2 = httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/task-statuses');
    tasksReq2.flush([task('t1'), task('t2')]);
    statusesReq2.flush(['backlog']);
    tick();

    expect(store.tasks().map((item) => item.id)).toEqual(['t1', 't2']);
    flush();
  }));

  it('hydrates from cache before a fetch completes', fakeAsync(() => {
    store.refresh();
    const tasksReq = httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/tasks');
    const statusesReq = httpMock.expectOne((req) => req.method === 'GET' && req.url === '/api/task-statuses');
    tasksReq.flush([task('cached')]);
    statusesReq.flush(['backlog']);
    tick();

    const fresh = TestBed.inject(TasksInventoryStore);
    fresh.hydrate();
    expect(fresh.tasks().map((item) => item.id)).toEqual(['cached']);
    expect(fresh.hasLoadedOnce()).toBe(true);
    expect(fresh.loading()).toBe(false);
    flush();
  }));
});
