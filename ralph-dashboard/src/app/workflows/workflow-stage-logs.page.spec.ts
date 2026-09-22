import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed, fakeAsync, tick, flush } from '@angular/core/testing';
import { ActivatedRoute } from '@angular/router';
import { signal } from '@angular/core';
import { WorkflowStageLogsPageComponent } from './workflow-stage-logs.page';
import { WorkspaceSelectorService } from '../services/workspace-selector.service';

describe('WorkflowStageLogsPageComponent', () => {
  let httpMock: HttpTestingController;

  function buildComponent(paramMap: Record<string, string>, queryParamMap: Record<string, string> = {}) {
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [WorkflowStageLogsPageComponent, HttpClientTestingModule],
      providers: [
        {
          provide: ActivatedRoute,
          useValue: {
            snapshot: {
              paramMap: { get: (key: string) => paramMap[key] ?? null },
              queryParamMap: { get: (key: string) => queryParamMap[key] ?? null },
            },
          },
        },
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath: signal<string | null>('/proj'),
            workspaces: signal([
              { path: '/proj', workspaceRoot: '/proj/.ralph-workspace', projectRoot: '/proj', label: 'p', exists: true },
            ]),
          },
        },
      ],
    });
    httpMock = TestBed.inject(HttpTestingController);
    const fixture = TestBed.createComponent(WorkflowStageLogsPageComponent);
    fixture.detectChanges();
    return fixture;
  }

  afterEach(() => {
    httpMock.verify();
  });

  it('loads stage log content on init', fakeAsync(() => {
    const fixture = buildComponent({ runId: 'run-1', stageId: 'stage-a' }, { attempt: '2' });

    httpMock
      .expectOne(
        (req) =>
          req.urlWithParams.startsWith('/api/workflow-runs/run-1/stages/stage-a/logs') &&
          req.params.get('attempt') === '2' &&
          req.params.get('workspaceRoot') === '/proj/.ralph-workspace',
      )
      .flush({ content: 'log line one\nlog line two' });

    tick();
    fixture.detectChanges();

    expect(fixture.componentInstance.runId()).toBe('run-1');
    expect(fixture.componentInstance.stageId()).toBe('stage-a');
    expect(fixture.componentInstance.attempt()).toBe(2);
    expect(fixture.componentInstance.content()).toBe('log line one\nlog line two');
    expect(fixture.componentInstance.loading()).toBe(false);
    flush();
  }));

  it('defaults attempt to 1 when query param is missing', fakeAsync(() => {
    const fixture = buildComponent({ runId: 'run-1', stageId: 'stage-a' });

    httpMock
      .expectOne((req) => req.urlWithParams.startsWith('/api/workflow-runs/run-1/stages/stage-a/logs') && req.params.get('attempt') === '1')
      .flush({ content: 'default attempt log' });

    tick();
    expect(fixture.componentInstance.attempt()).toBe(1);
    expect(fixture.componentInstance.content()).toBe('default attempt log');
    flush();
  }));

  it('shows empty state when content is absent', fakeAsync(() => {
    const fixture = buildComponent({ runId: 'run-1', stageId: 'stage-a' });

    httpMock
      .expectOne((req) => req.urlWithParams.startsWith('/api/workflow-runs/run-1/stages/stage-a/logs'))
      .flush({ content: '' });

    tick();
    fixture.detectChanges();

    expect(fixture.componentInstance.content()).toBe('');
    expect(fixture.nativeElement.textContent).toContain('No log output has been recorded');
    flush();
  }));

  it('shows error when log fetch fails', fakeAsync(() => {
    const fixture = buildComponent({ runId: 'run-1', stageId: 'stage-a' });

    httpMock
      .expectOne((req) => req.urlWithParams.startsWith('/api/workflow-runs/run-1/stages/stage-a/logs'))
      .flush('error', { status: 500, statusText: 'Error' });

    tick();
    fixture.detectChanges();

    expect(fixture.componentInstance.error()).toBeTruthy();
    expect(fixture.componentInstance.loading()).toBe(false);
    flush();
  }));

  it('unsubscribes previous request on refresh', fakeAsync(() => {
    const fixture = buildComponent({ runId: 'run-1', stageId: 'stage-a' });

    httpMock
      .expectOne((req) => req.urlWithParams.startsWith('/api/workflow-runs/run-1/stages/stage-a/logs'))
      .flush({ content: 'first' });
    tick();

    fixture.componentInstance.load();
    httpMock
      .expectOne((req) => req.urlWithParams.startsWith('/api/workflow-runs/run-1/stages/stage-a/logs'))
      .flush({ content: 'second' });
    tick();

    expect(fixture.componentInstance.content()).toBe('second');
    flush();
  }));
});
