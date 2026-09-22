import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pollAttempt, type TaskAttempt } from '../src/server/task-schedule-api';

const roots = { projectRoot: '/project', workspaceRoot: '/project/.ralph-workspace' };
const oldBin = process.env['RALPH_DASHBOARD_RALPH_BIN'];
let fixtureDir = '';

function workflowAttempt(overrides: Partial<TaskAttempt> = {}): TaskAttempt {
  return {
    id: 'attempt-1',
    startedAt: new Date(Date.now() - 11 * 60_000).toISOString(),
    status: 'running',
    executionKind: 'workflow',
    runId: 'run-1',
    pid: 999_999_999,
    logPath: join(fixtureDir, 'attempt.log'),
    ...overrides,
  };
}

beforeEach(() => {
  fixtureDir = mkdtempSync(join(tmpdir(), 'ralph-attempt-liveness-'));
  const bin = join(fixtureDir, 'ralph-stub');
  writeFileSync(bin, '#!/usr/bin/env bash\necho "dashboard CLI unavailable" >&2\nexit 1\n');
  chmodSync(bin, 0o755);
  process.env['RALPH_DASHBOARD_RALPH_BIN'] = bin;
});

afterEach(() => {
  rmSync(fixtureDir, { recursive: true, force: true });
  if (oldBin === undefined) delete process.env['RALPH_DASHBOARD_RALPH_BIN'];
  else process.env['RALPH_DASHBOARD_RALPH_BIN'] = oldBin;
});

describe('pollAttempt liveness reconciliation', () => {
  it('fails a stale dead-PID workflow attempt when the CLI status probe fails', async () => {
    const attempt = workflowAttempt();
    await expect(pollAttempt(attempt, roots)).resolves.toMatchObject({
      runId: 'run-1',
      status: 'failed',
      error: expect.stringMatching(/Unable to reconcile workflow run run-1/),
    });
    // Reconciliation is deterministic: a later refresh cannot turn this
    // stale, dead process claim back into an active attempt.
    await expect(pollAttempt(attempt, roots)).resolves.toMatchObject({ status: 'failed' });
  });

  it('keeps a live-PID attempt running when a temporary CLI probe fails', async () => {
    await expect(pollAttempt(workflowAttempt({ pid: process.pid }), roots)).resolves.toBeNull();
  });
});
