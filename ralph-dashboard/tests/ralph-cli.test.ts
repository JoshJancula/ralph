import { parseManagedProcessRuns } from '../src/server/ralph-cli';

describe('parseManagedProcessRuns', () => {
  it('normalizes valid registry rows and ignores malformed rows', () => {
    const runs = parseManagedProcessRuns(JSON.stringify([
      {
        run_id: 'run-1', kind: 'plan', plan_path: '/project/plans/PLAN.md',
        owner_pid: 42, owner_alive: true, live_processes: 3, started_at: '2026-09-16T12:00:00Z',
      },
      { run_id: 'missing-path', kind: 'plan' },
      null,
      { run_id: 'workflow-1', kind: 'orchestrator', plan_path: '/project/workflow.md', owner_alive: false },
    ]));

    expect(runs).toEqual([
      {
        id: 'run-1', kind: 'plan', planPath: '/project/plans/PLAN.md',
        ownerPid: 42, ownerAlive: true, liveProcesses: 3, startedAt: '2026-09-16T12:00:00Z',
      },
      {
        id: 'workflow-1', kind: 'orchestrator', planPath: '/project/workflow.md',
        ownerPid: null, ownerAlive: false, liveProcesses: 0, startedAt: null,
      },
    ]);
  });

  it('rejects a non-array payload', () => {
    expect(parseManagedProcessRuns('{}')).toEqual([]);
  });
});
