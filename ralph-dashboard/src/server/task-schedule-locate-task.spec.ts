import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { locateTaskStore, type Task } from './task-schedule-api';

function writeProjectStore(workspaceRoot: string, tasks: Task[]): void {
  const dir = join(workspaceRoot, 'dashboard');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'tasks-schedules.json'), JSON.stringify({ tasks, schedules: [] }, null, 2));
}

describe('locateTaskStore', () => {
  it('finds a project task in the dashboard home store when launch uses target workspace roots', async () => {
    const homeRoot = mkdtempSync(join(tmpdir(), 'ralph-home-'));
    const homeWorkspace = join(homeRoot, '.ralph-workspace');
    const execRoot = mkdtempSync(join(tmpdir(), 'ralph-exec-'));
    const execWorkspace = join(execRoot, '.ralph-workspace');
    mkdirSync(homeWorkspace, { recursive: true });
    mkdirSync(execWorkspace, { recursive: true });

    const task: Task = {
      id: 'task-home-only',
      title: 'Coverage',
      workflowId: 'feature-delivery',
      scope: 'project',
      targetWorkspaceRoot: execWorkspace,
      status: 'ready',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
      attempts: [],
    };
    writeProjectStore(homeWorkspace, [task]);
    writeProjectStore(execWorkspace, []);

    const located = await locateTaskStore(
      task.id,
      { projectRoot: execRoot, workspaceRoot: execWorkspace },
      { projectRoot: homeRoot, workspaceRoot: homeWorkspace },
    );

    expect(located).toEqual({
      scope: 'project',
      storeRoots: { projectRoot: homeRoot, workspaceRoot: homeWorkspace },
    });
  });
});
