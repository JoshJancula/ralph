import '@angular/compiler';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import type { Request, Response } from 'express';

import { clearDashboardRootsCache, clearWorkspaceRootsCache } from '../src/paths';
import {
  clearMergedWorkspaceAllowlistCache,
  handleGraphRunsRequest,
  enumerateRegisteredWorkspaces,
} from '../src/server/dashboard-api';
import type { GraphRunSummary } from '../src/server/dashboard-api';

interface MockResponse {
  statusCode: number;
  body: unknown;
  status(code: number): MockResponse;
  json(payload: unknown): MockResponse;
}

function createMockResponse(): MockResponse {
  const res: MockResponse = {
    statusCode: 200,
    body: undefined,
    status(code: number) {
      this.statusCode = code;
      return this;
    },
    json(payload: unknown) {
      this.body = payload;
      return this;
    },
  };
  return res;
}

function createMockRequest(query: Record<string, string>): Request {
  return { query } as unknown as Request;
}

function createRun(
  workspaceRoot: string,
  namespace: string,
  runId: string,
  startedAt: string,
  status: string,
  nodeCount: number,
  isLatest = false,
): void {
  const nsDir = join(workspaceRoot, 'graph-runs', namespace);
  const runDir = join(nsDir, runId);
  mkdirSync(join(runDir, 'nodes'), { recursive: true });
  writeFileSync(
    join(runDir, 'run.json'),
    JSON.stringify({ runId, startedAt, status }),
    'utf8',
  );
  for (let i = 0; i < nodeCount; i++) {
    writeFileSync(
      join(runDir, 'nodes', `node-${i}.json`),
      JSON.stringify({ nodeId: `node-${i}`, status: 'succeeded', attempts: [] }),
      'utf8',
    );
  }
  if (isLatest) {
    symlinkSync(runId, join(nsDir, 'latest'));
  }
}

describe('handleGraphRunsRequest', () => {
  let tempRoot = '';
  let originalWorkspacesFile: string | undefined;
  let originalDashboardWorkspaceRoot: string | undefined;
  let originalDashboardGlobal: string | undefined;
  let originalCwd: string | undefined;

  beforeAll(() => {
    originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];
    originalDashboardWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalDashboardGlobal = process.env['RALPH_DASHBOARD_GLOBAL'];
  });

  beforeEach(() => {
    clearMergedWorkspaceAllowlistCache();
    clearDashboardRootsCache();
    clearWorkspaceRootsCache();
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-graph-runs-'));
    process.chdir(tempRoot);

    mkdirSync(join(tempRoot, '.ralph-workspace'), { recursive: true });
    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = tempRoot;
    process.env['RALPH_WORKSPACES_FILE'] = join(tempRoot, 'workspaces.json');
    delete process.env['RALPH_DASHBOARD_GLOBAL'];
    writeFileSync(process.env['RALPH_WORKSPACES_FILE']!, '[]');
  });

  afterEach(() => {
    if (originalCwd) {
      process.chdir(originalCwd);
    }
    if (tempRoot) {
      rmSync(tempRoot, { recursive: true, force: true });
    }
    clearMergedWorkspaceAllowlistCache();
    clearDashboardRootsCache();
    clearWorkspaceRootsCache();
  });

  afterAll(() => {
    if (originalWorkspacesFile === undefined) {
      delete process.env['RALPH_WORKSPACES_FILE'];
    } else {
      process.env['RALPH_WORKSPACES_FILE'] = originalWorkspacesFile;
    }
    if (originalDashboardWorkspaceRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalDashboardWorkspaceRoot;
    }
    if (originalDashboardGlobal === undefined) {
      delete process.env['RALPH_DASHBOARD_GLOBAL'];
    } else {
      process.env['RALPH_DASHBOARD_GLOBAL'] = originalDashboardGlobal;
    }
  });

  function setRegistry(entries: Array<{ path: string }>): void {
    writeFileSync(process.env['RALPH_WORKSPACES_FILE']!, JSON.stringify(entries));
  }

  it('merges graph runs from multiple live workspaces newest-first', async () => {
    const wsA = join(tempRoot, 'ws-a');
    const wsB = join(tempRoot, 'ws-b');
    const wsRootA = join(wsA, '.ralph-workspace');
    const wsRootB = join(wsB, '.ralph-workspace');

    mkdirSync(wsRootA, { recursive: true });
    mkdirSync(wsRootB, { recursive: true });

    createRun(wsRootA, 'ns', 'run-20260103T000000Z-a', '2026-01-03T00:00:00Z', 'succeeded', 2, true);
    createRun(wsRootA, 'ns', 'run-20260101T000000Z-a', '2026-01-01T00:00:00Z', 'succeeded', 1, false);
    createRun(wsRootB, 'ns', 'run-20260102T000000Z-b', '2026-01-02T00:00:00Z', 'running', 3, true);

    setRegistry([{ path: wsA }, { path: wsB }]);

    const res = createMockResponse();
    await handleGraphRunsRequest(createMockRequest({}), res as unknown as Response);

    expect(res.statusCode).toBe(200);
    const body = res.body as { runs: GraphRunSummary[]; skipped?: number };
    const scoped = body.runs.filter((r) => r.projectRoot.startsWith(tempRoot));
    expect(scoped).toHaveLength(3);

    // Latest runs first, then by startedAt descending.
    expect(scoped[0].runId).toBe('run-20260103T000000Z-a');
    expect(scoped[0].isLatest).toBe(true);
    expect(scoped[1].runId).toBe('run-20260102T000000Z-b');
    expect(scoped[1].isLatest).toBe(true);
    expect(scoped[2].runId).toBe('run-20260101T000000Z-a');
    expect(scoped[2].isLatest).toBe(false);

    expect(scoped[0].workspaceRoot).toBe(resolve(wsRootA));
    expect(scoped[0].projectRoot).toBe(resolve(wsA));
    expect(scoped[1].workspaceRoot).toBe(resolve(wsRootB));
    expect(scoped[1].projectRoot).toBe(resolve(wsB));

    expect(body.skipped).toBe(0);
  });

  it('counts skipped dead workspace entries in merged response', async () => {
    const live = join(tempRoot, 'live');
    const dead = join(tempRoot, 'dead');
    const wsRootLive = join(live, '.ralph-workspace');
    mkdirSync(wsRootLive, { recursive: true });

    createRun(wsRootLive, 'ns', 'run-20260101T000000Z-live', '2026-01-01T00:00:00Z', 'succeeded', 1, true);
    setRegistry([
      { path: live },
      { path: dead, planKey: 'dead-plan', runtime: 'claude' },
    ]);

    const res = createMockResponse();
    await handleGraphRunsRequest(createMockRequest({}), res as unknown as Response);

    expect(res.statusCode).toBe(200);
    const body = res.body as { runs: GraphRunSummary[]; skipped?: number };
    const scopedDead = body.runs.filter((r) => r.projectRoot.startsWith(tempRoot));
    expect(scopedDead).toHaveLength(1);
    expect(scopedDead[0].projectRoot).toBe(resolve(live));
    expect(body.skipped).toBe(1);
  });

  it('preserves single-root behavior when workspaceRoot query is explicit', async () => {
    const wsA = join(tempRoot, 'ws-a');
    const wsB = join(tempRoot, 'ws-b');
    const wsRootA = join(wsA, '.ralph-workspace');
    const wsRootB = join(wsB, '.ralph-workspace');
    mkdirSync(wsRootA, { recursive: true });
    mkdirSync(wsRootB, { recursive: true });

    createRun(wsRootA, 'ns', 'run-a', '2026-01-01T00:00:00Z', 'succeeded', 1, true);
    createRun(wsRootB, 'ns', 'run-b', '2026-01-01T00:00:00Z', 'succeeded', 1, true);
    setRegistry([{ path: wsA }, { path: wsB }]);

    const res = createMockResponse();
    await handleGraphRunsRequest(
      createMockRequest({ workspaceRoot: wsRootB }),
      res as unknown as Response,
    );

    expect(res.statusCode).toBe(200);
    const body = res.body as { runs: GraphRunSummary[]; skipped?: number };
    expect(body.runs).toHaveLength(1);
    expect(body.runs[0].runId).toBe('run-b');
    expect(body.runs[0].projectRoot).toBe(resolve(wsB));
    expect(body.skipped).toBeUndefined();
  });

  it('applies limit cap and clamps over-large values', async () => {
    const ws = join(tempRoot, 'ws');
    const wsRoot = join(ws, '.ralph-workspace');
    mkdirSync(wsRoot, { recursive: true });

    for (let i = 0; i < 5; i++) {
      const day = String(i + 1).padStart(2, '0');
      createRun(
        wsRoot,
        'ns',
        `run-202601${day}T000000Z`,
        `2026-01-${day}T00:00:00Z`,
        'succeeded',
        1,
        i === 4,
      );
    }
    setRegistry([{ path: ws }]);
    clearMergedWorkspaceAllowlistCache();
    clearDashboardRootsCache();
    clearWorkspaceRootsCache();
    const res = createMockResponse();
    await handleGraphRunsRequest(createMockRequest({ workspaceRoot: wsRoot, limit: '3' }), res as unknown as Response);

    expect(res.statusCode).toBe(200);
    const body = res.body as { runs: GraphRunSummary[] };
    expect(body.runs).toHaveLength(3);
    expect(body.runs[0].runId).toBe('run-20260105T000000Z');
    expect(body.runs[2].runId).toBe('run-20260103T000000Z');
    expect(body.runs[0].projectRoot).toBe(resolve(ws));
  });

  it('ignores invalid limit and falls back to default cap', async () => {
    const ws = join(tempRoot, 'ws');
    const wsRoot = join(ws, '.ralph-workspace');
    mkdirSync(wsRoot, { recursive: true });

    createRun(wsRoot, 'ns', 'run-1', '2026-01-01T00:00:00Z', 'succeeded', 1, true);
    setRegistry([{ path: ws }]);
    const res = createMockResponse();
    await handleGraphRunsRequest(createMockRequest({ limit: 'abc' }), res as unknown as Response);

    expect(res.statusCode).toBe(200);
    const body = res.body as { runs: GraphRunSummary[] };
    const scopedInvalid = body.runs.filter((r) => r.projectRoot.startsWith(tempRoot));
    expect(scopedInvalid).toHaveLength(1);
  });

  it('returns empty runs when no workspaces have graph-runs', async () => {
    const ws = join(tempRoot, 'ws');
    mkdirSync(join(ws, '.ralph-workspace'), { recursive: true });
    setRegistry([{ path: ws }]);

    const res = createMockResponse();
    await handleGraphRunsRequest(createMockRequest({}), res as unknown as Response);

    expect(res.statusCode).toBe(200);
    const body = res.body as { runs: GraphRunSummary[]; skipped?: number };
    expect(body.runs.filter((r) => r.projectRoot.startsWith(tempRoot))).toEqual([]);
    expect(body.skipped).toBe(0);
  });
});
