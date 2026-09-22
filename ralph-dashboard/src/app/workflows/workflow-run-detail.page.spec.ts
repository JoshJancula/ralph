import '../../angular-test-env';
import { provideRouter, ActivatedRoute, convertToParamMap } from '@angular/router';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { of } from 'rxjs';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { WorkflowRunDetailPageComponent } from './workflow-run-detail.page';
import { WorkflowsFacade } from './workflows.facade';
import { CapabilitiesService } from './capabilities.service';
import type { RunStatus } from './workflow.types';
import { enrichWorkflowRunDetail } from '../../server/workflow-run-detail';

function createMockRunStatus(
  state: string,
  stages: readonly Record<string, unknown>[] = [],
  extras: {
    diagnosis?: Record<string, unknown>;
    nextAction?: unknown;
    actions?: unknown[];
  } = {},
): RunStatus {
  const raw = {
    schemaVersion: 1,
    run: {
      state,
      workflowId: 'test-workflow',
      runId: 'run-1',
      task: 'fix the model picker defaults',
      createdAt: '2026-09-14T10:00:00Z',
      updatedAt: '2026-09-14T10:05:00Z',
    },
    stages,
    diagnosis: {
      state,
      reasonCode: 'none',
      summary: '',
      stageId: null,
      requestKind: null,
      requestId: null,
      evidence: [],
      retryable: true,
      nextAction: null,
      ...(extras.diagnosis ?? {}),
    },
    nextAction: extras.nextAction ?? null,
  };
  const enriched = enrichWorkflowRunDetail(raw, extras.actions ?? []);
  return enriched;
}

function fakeFacade(runStatus: RunStatus | null = null) {
  return {
    loadRunStatus: vi.fn(async () => undefined),
    stopRunStatusPolling: vi.fn(),
    listRunActions: vi.fn(async () => []),
    cancelRun: vi.fn(async () => true),
    resumeRun: vi.fn(async () => true),
    resetRun: vi.fn(async () => true),
    respondAction: vi.fn(async () => true),
    runStatus: signal(runStatus),
  };
}

function fakeCapabilities(workflowRuns = true) {
  return { load: vi.fn(), capabilities: signal({ workflowWrites: workflowRuns, workflowRuns, assistant: workflowRuns }) };
}

describe('WorkflowRunDetailPageComponent', () => {
  async function build(facade: ReturnType<typeof fakeFacade>, capabilities = fakeCapabilities(), runId = 'run-1') {
    await TestBed.configureTestingModule({
      imports: [WorkflowRunDetailPageComponent],
      providers: [
        provideRouter([]),
        { provide: WorkflowsFacade, useValue: facade },
        { provide: CapabilitiesService, useValue: capabilities },
        { provide: ActivatedRoute, useValue: { paramMap: of(convertToParamMap({ runId })) } },
      ],
    }).compileComponents();
    const fixture: ComponentFixture<WorkflowRunDetailPageComponent> = TestBed.createComponent(WorkflowRunDetailPageComponent);
    fixture.detectChanges();
    return fixture;
  }

  it('loads run status for the :runId route param', async () => {
    const facade = fakeFacade();
    await build(facade);
    expect(facade.loadRunStatus).toHaveBeenCalledWith('run-1');
  });

  it('shows the originating task text so a finished run can be reviewed', async () => {
    const fixture = await build(fakeFacade(createMockRunStatus('failed')));
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="run-detail-user-prompt"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="run-detail-task"]')?.textContent).toContain(
      'fix the model picker defaults',
    );
  });

  it('omits the task line when the run records no task', async () => {
    const status = createMockRunStatus('failed');
    delete (status as unknown as { run: Record<string, unknown> }).run['task'];
    const fixture = await build(fakeFacade(status));
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="run-detail-task"]')).toBeNull();
  });

  it('hides all controls when capabilities.workflowRuns is false', async () => {
    const fixture = await build(fakeFacade(), fakeCapabilities(false));
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="run-controls-disabled"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="run-cancel"]')).toBeNull();
    expect(el.querySelector('[data-testid="run-resume"]')).toBeNull();
  });

  it('cancel requires a confirmation step before calling facade.cancelRun', async () => {
    const facade = fakeFacade(createMockRunStatus('running'));
    const fixture = await build(facade);
    const el: HTMLElement = fixture.nativeElement;
    (el.querySelector('[data-testid="run-cancel"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(facade.cancelRun).not.toHaveBeenCalled();
    expect(el.querySelector('[data-testid="run-cancel-confirm"]')).not.toBeNull();

    (el.querySelector('[data-testid="run-cancel-yes"]') as HTMLButtonElement).click();
    await Promise.resolve();
    expect(facade.cancelRun).toHaveBeenCalledWith('run-1');
  });

  it('resume calls facade.resumeRun directly, no confirmation step', async () => {
    const facade = fakeFacade(
      createMockRunStatus('waiting', [], {
        diagnosis: { reasonCode: 'operator-input', summary: 'answered; resume', state: 'waiting' },
        nextAction: { label: 'Resume workflow', argv: ['ralph', 'workflow', 'resume', 'run-1'] },
        actions: [{ requestId: 'req-1', kind: 'input', question: 'q', status: 'answered', decision: { decision: 'answer' } }],
      }),
    );
    const fixture = await build(facade);
    (fixture.nativeElement.querySelector('[data-testid="run-resume"]') as HTMLButtonElement).click();
    await Promise.resolve();
    expect(facade.resumeRun).toHaveBeenCalledWith('run-1');
  });

  it('shows an empty state when there are no action requests', async () => {
    const fixture = await build(fakeFacade(createMockRunStatus('running')));
    expect(fixture.nativeElement.querySelector('[data-testid="pending-actions-empty"]')).not.toBeNull();
  });

  it('renders a pending action and responds with approve without a message', async () => {
    const facade = fakeFacade(
      createMockRunStatus('waiting', [], {
        diagnosis: { reasonCode: 'human-approval', stageId: 'gate', requestId: 'req-1', state: 'waiting' },
        nextAction: { label: 'answer the outstanding request', argv: ['ralph', 'workflow', 'actions', 'list', 'run-1'] },
        actions: [{ requestId: 'req-1', kind: 'approval', question: 'Approve this plan?', status: 'outstanding', choices: ['approve', 'request-changes', 'cancel'] }],
      }),
    );
    const fixture = await build(facade);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="pending-action-req-1"]')?.textContent).toContain('Approve this plan?');

    (el.querySelector('[data-testid="respond-req-1-approve"]') as HTMLButtonElement).click();
    await Promise.resolve();
    expect(facade.respondAction).toHaveBeenCalledWith('run-1', { requestId: 'req-1', decision: 'approve', message: undefined });
  });

  it('a message-required decision (request-changes) shows a message box before sending', async () => {
    const facade = fakeFacade(
      createMockRunStatus('waiting', [], {
        actions: [{ requestId: 'req-1', kind: 'approval', question: 'Approve this plan?', status: 'outstanding', choices: ['approve', 'request-changes', 'cancel'] }],
      }),
    );
    const fixture = await build(facade);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    (el.querySelector('[data-testid="respond-req-1-request-changes"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(facade.respondAction).not.toHaveBeenCalled();
    const sendBtn = el.querySelector('[data-testid="respond-send-req-1"]') as HTMLButtonElement;
    expect(sendBtn.disabled).toBe(true);

    fixture.componentInstance.messages['req-1'] = 'please fix the plan';
    await fixture.componentInstance.sendResponseWithMessage('req-1');
    expect(facade.respondAction).toHaveBeenCalledWith('run-1', { requestId: 'req-1', decision: 'request-changes', message: 'please fix the plan' });
  });

  it('run status polling is stopped on component destroy', async () => {
    const facade = fakeFacade();
    const fixture = await build(facade);
    fixture.destroy();
    expect(facade.stopRunStatusPolling).toHaveBeenCalled();
  });

  describe('run states', () => {
    it('shows successful run with completed stages and immutable/control plan distinction', async () => {
      const runStatus = createMockRunStatus('succeeded', [
        {
          id: 'stage-1',
          state: 'succeeded',
          stageKind: 'plan-backed',
          attempt: 1,
          sourcePlanPath: '/r/source.plan.md',
          controlPlanPath: '/r/control.plan.md',
          completedTodos: 2,
          totalTodos: 2,
          artifacts: ['out.md'],
          evidence: ['out.md'],
        },
      ]);
      const facade = fakeFacade(runStatus);
      const fixture = await build(facade);
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('[data-testid="run-state"]')?.textContent).toContain('Completed');
      expect(el.querySelector('[data-testid="stage-stage-1"]')).not.toBeNull();
      (el.querySelector('[data-testid="stage-stage-1"] details') as HTMLDetailsElement).open = true;
      fixture.detectChanges();
      expect(el.querySelector('[data-testid="stage-plan-paths"]')?.textContent).toMatch(/immutable/i);
      expect(el.querySelector('[data-testid="stage-plan-paths"]')?.textContent).toMatch(/mutable/i);
      expect(el.querySelector('[data-testid="stage-todo-progress"]')?.textContent).toContain('2/2');
    });

    it('shows waiting-for-input with dominant next action and enabled respond controls', async () => {
      const runStatus = createMockRunStatus(
        'waiting',
        [{ id: 'stage-2', state: 'waiting', stageKind: 'executable', attempt: 1, requestId: 'req-1', requestState: 'outstanding' }],
        {
          diagnosis: {
            state: 'waiting',
            reasonCode: 'operator-input',
            summary: 'Provide input for stage-2',
            stageId: 'stage-2',
            requestId: 'req-1',
          },
          nextAction: { label: 'answer the outstanding request', argv: ['ralph', 'workflow', 'actions', 'list', 'run-1'] },
          actions: [{ requestId: 'req-1', kind: 'input', question: 'Provide input for stage-2', status: 'outstanding', choices: ['answer'] }],
        },
      );
      const facade = fakeFacade(runStatus);
      const fixture = await build(facade);
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('[data-testid="run-state"]')?.textContent).toContain('Waiting');
      expect(el.querySelector('[data-testid="next-action-panel"]')).not.toBeNull();
      expect(el.querySelector('[data-testid="pending-action-req-1"]')).not.toBeNull();
      expect((el.querySelector('[data-testid="respond-req-1-answer"]') as HTMLButtonElement).disabled).toBe(false);
      expect((el.querySelector('[data-testid="run-resume"]') as HTMLButtonElement).disabled).toBe(true);
      expect(el.querySelector('[data-testid="resume-disabled-reason"]')?.textContent).toMatch(/outstanding|before resume/i);
    });

    it('shows request-changes with reset as the dominant next action', async () => {
      const runStatus = createMockRunStatus(
        'blocked',
        [
          { id: 'plan-implementation', state: 'succeeded', stageKind: 'plan-backed', attempt: 1 },
          { id: 'human-gate', state: 'blocked', stageKind: 'approval', attempt: 1, requestId: 'req-1', requestState: 'answered' },
        ],
        {
          diagnosis: {
            state: 'blocked',
            reasonCode: 'human-changes-requested',
            summary: 'reset plan-implementation and resume',
            stageId: 'human-gate',
            requestId: 'req-1',
          },
          nextAction: {
            label: 'reset to the approval changes target',
            argv: ['ralph', 'workflow', 'reset', 'run-1', '--stage', 'plan-implementation'],
          },
          actions: [
            {
              requestId: 'req-1',
              kind: 'approval',
              question: 'Approve?',
              status: 'answered',
              decision: { decision: 'request-changes', message: 'fix API', decidedAt: '2026-09-14T10:04:00Z' },
            },
          ],
        },
      );
      const facade = fakeFacade(runStatus);
      const fixture = await build(facade);
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('[data-testid="next-action-label"]')?.textContent).toMatch(/reset/i);
      expect(el.querySelector('[data-testid="run-reset"]')).not.toBeNull();
      expect(el.querySelector('[data-testid="action-decision-req-1"]')?.textContent).toMatch(/request-changes/);
      expect(el.querySelector('[data-testid="action-disabled-req-1"]')?.textContent).toMatch(/persisted|resume/i);
      expect((el.querySelector('[data-testid="respond-req-1-approve"]') as HTMLButtonElement | null)?.disabled).toBe(true);
    });

    it('shows failed verification state with evidence', async () => {
      const runStatus = createMockRunStatus(
        'failed',
        [
          {
            id: 'qa',
            state: 'failed',
            stageKind: 'executable',
            attempt: 1,
            reasonCode: 'stage-failed',
            artifacts: ['qa-verdict.json'],
            evidence: ['qa-verdict.json'],
          },
        ],
        {
          diagnosis: { state: 'failed', reasonCode: 'stage-failed', summary: 'Verification failed', stageId: 'qa' },
        },
      );
      const facade = fakeFacade(runStatus);
      const fixture = await build(facade);
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('[data-testid="run-state"]')?.textContent).toContain('Failed');
      expect(el.querySelector('[data-testid="stage-qa"]')?.textContent).toMatch(/Verification failed|Failed/i);
      (el.querySelector('[data-testid="stage-qa"] details') as HTMLDetailsElement).open = true;
      fixture.detectChanges();
      expect(el.querySelector('[data-testid="stage-produced-evidence"]')?.textContent).toContain('qa-verdict.json');
    });

    it('shows rework state with multiple attempts', async () => {
      const runStatus = createMockRunStatus('running', [
        { id: 'stage-1', state: 'running', stageKind: 'plan-backed', attempt: 2, completedTodos: 1, totalTodos: 3 },
      ]);
      const facade = fakeFacade(runStatus);
      const fixture = await build(facade);
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('[data-testid="stage-attempt"]')?.textContent).toContain('Attempt 2');
      expect(el.querySelector('[data-testid="stage-attempt"]')?.textContent).toMatch(/rework round 2/i);
    });

    it('disables resume button when run is in terminal state', async () => {
      const runStatus = createMockRunStatus('succeeded');
      const facade = fakeFacade(runStatus);
      const fixture = await build(facade);
      fixture.detectChanges();
      const resumeBtn = fixture.nativeElement.querySelector('[data-testid="run-resume"]') as HTMLButtonElement;
      expect(resumeBtn.disabled).toBe(true);
    });

    it('disables cancel button when run is in terminal state', async () => {
      const runStatus = createMockRunStatus('failed');
      const facade = fakeFacade(runStatus);
      const fixture = await build(facade);
      fixture.detectChanges();
      const cancelBtn = fixture.nativeElement.querySelector('[data-testid="run-cancel"]') as HTMLButtonElement;
      expect(cancelBtn.disabled).toBe(true);
    });
  });

  describe('timeline events', () => {
    it('displays a chronological timeline of supervisor-translated events', async () => {
      const runStatus = createMockRunStatus(
        'waiting',
        [{ id: 'stage-1', state: 'waiting', attempt: 1, createdAt: '2026-09-14T10:01:00Z', updatedAt: '2026-09-14T10:01:00Z' }],
        {
          actions: [{ requestId: 'req-1', kind: 'approval', question: 'Approve?', status: 'outstanding', createdAt: '2026-09-14T10:02:00Z' }],
          diagnosis: { reasonCode: 'human-approval', summary: 'Approval requested', stageId: 'stage-1', state: 'waiting' },
        },
      );
      const facade = fakeFacade(runStatus);
      const fixture = await build(facade);
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('[data-testid="timeline-section"]')).not.toBeNull();
      expect(el.querySelectorAll('[data-testid^="event-"]').length).toBeGreaterThan(0);
    });
  });

  describe('action response persistence', () => {
    it('shows persisted decision and disables respond after answered status', async () => {
      const runStatus = createMockRunStatus('waiting', [], {
        actions: [
          {
            requestId: 'req-1',
            kind: 'approval',
            question: 'Approve?',
            status: 'answered',
            decision: { decision: 'approve', decidedAt: '2026-09-14T10:03:00Z' },
          },
        ],
        nextAction: { label: 'Resume workflow', argv: ['ralph', 'workflow', 'resume', 'run-1'] },
        diagnosis: { reasonCode: 'human-approval', summary: 'approved; resume', state: 'waiting' },
      });
      const facade = fakeFacade(runStatus);
      const fixture = await build(facade);
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('[data-testid="action-decision-req-1"]')?.textContent).toMatch(/approve/i);
      expect(el.querySelector('[data-testid="action-status-req-1"]')?.textContent).toContain('answered');
      expect((el.querySelector('[data-testid="respond-req-1-approve"]') as HTMLButtonElement).disabled).toBe(true);
      expect(el.querySelector('[data-testid="action-disabled-req-1"]')?.textContent).toMatch(/persisted|resume/i);
    });
  });

  it('reset primary control calls facade.resetRun with the changes target', async () => {
    const runStatus = createMockRunStatus(
      'blocked',
      [],
      {
        diagnosis: { reasonCode: 'human-changes-requested', summary: 'reset plan-implementation', state: 'blocked' },
        nextAction: {
          label: 'reset to the approval changes target',
          argv: ['ralph', 'workflow', 'reset', 'run-1', '--stage', 'plan-implementation'],
        },
      },
    );
    const facade = fakeFacade(runStatus);
    const fixture = await build(facade);
    fixture.detectChanges();
    (fixture.nativeElement.querySelector('[data-testid="run-reset-primary"]') as HTMLButtonElement).click();
    await Promise.resolve();
    expect(facade.resetRun).toHaveBeenCalledWith('run-1', { stage: 'plan-implementation' });
  });
});
