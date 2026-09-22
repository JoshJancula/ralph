import '@angular/compiler';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Request, Response } from 'express';

import { clearDashboardRootsCache, clearWorkspaceRootsCache } from '../src/paths';
import {
  clearMergedWorkspaceAllowlistCache,
  handleGraphRunsRequest,
  handlePlanRunDetailRequest,
  handlePlanRunsListRequest,
} from '../src/server/dashboard-api';
import {
  buildRunNavigationSummary,
  groupRunsByParent,
  isCandidateWorkspaceTreePath,
  listCatalogRuns,
  listNavigableRuns,
} from '../src/server/state-navigation';

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

function asReq(params: Record<string, string> = {}, query: Record<string, string> = {}): Request {
  return { params, query } as unknown as Request;
}

describe('state navigation', () => {
  let fixtureRoot = '';
  let mixedRoot = '';
  let tempRoot = '';
  let workspaceRoot = '';
  let originalWorkspacesFile: string | undefined;
  let originalDashboardWorkspaceRoot: string | undefined;
  let originalDashboardGlobal: string | undefined;
  let originalCwd: string | undefined;

  beforeAll(() => {
    fixtureRoot = mkdtempSync(join(tmpdir(), 'ralph-state-nav-'));
    execFileSync('bash', [
      join(process.cwd(), '..', 'tests', 'fixtures', 'state-layout', 'generate-fixtures.sh'),
      fixtureRoot,
    ]);
    mixedRoot = join(fixtureRoot, 'mixed');
    originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];
    originalDashboardWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalDashboardGlobal = process.env['RALPH_DASHBOARD_GLOBAL'];
  });

  afterAll(() => {
    rmSync(fixtureRoot, { recursive: true, force: true });
    if (originalWorkspacesFile === undefined) delete process.env['RALPH_WORKSPACES_FILE'];
    else process.env['RALPH_WORKSPACES_FILE'] = originalWorkspacesFile;
    if (originalDashboardWorkspaceRoot === undefined) delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    else process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalDashboardWorkspaceRoot;
    if (originalDashboardGlobal === undefined) delete process.env['RALPH_DASHBOARD_GLOBAL'];
    else process.env['RALPH_DASHBOARD_GLOBAL'] = originalDashboardGlobal;
  });

  beforeEach(() => {
    clearMergedWorkspaceAllowlistCache();
    clearDashboardRootsCache();
    clearWorkspaceRootsCache();
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-nav-dash-'));
    process.chdir(tempRoot);
    workspaceRoot = join(tempRoot, '.ralph-workspace');
    mkdirSync(workspaceRoot, { recursive: true });
    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = tempRoot;
    process.env['RALPH_WORKSPACES_FILE'] = join(tempRoot, 'workspaces.json');
    delete process.env['RALPH_DASHBOARD_GLOBAL'];
    writeFileSync(process.env['RALPH_WORKSPACES_FILE']!, '[]');
  });

  afterEach(() => {
    if (originalCwd) process.chdir(originalCwd);
    rmSync(tempRoot, { recursive: true, force: true });
  });

  test('lists layout-2 runs from the catalog only and ignores candidate workspace trees', () => {
    const catalogs = listCatalogRuns(mixedRoot);
    expect(catalogs.map((r) => r.runId)).toEqual(['run-2']);
    expect(catalogs[0]?.layoutVersion).toBe(2);
    expect(catalogs[0]?.task).toBe('ship it');

    // Decoy deep under a candidate workspace must not appear via catalog listing.
    mkdirSync(join(mixedRoot, 'runs/run-2/engine/graph/workspaces/candidate-x'), { recursive: true });
    writeFileSync(
      join(mixedRoot, 'runs/run-2/engine/graph/workspaces/candidate-x/run.json'),
      JSON.stringify({ kind: 'ralph_run_catalog', layoutVersion: 2, runId: 'decoy', runKind: 'graph' }),
    );
    expect(listCatalogRuns(mixedRoot).map((r) => r.runId)).toEqual(['run-2']);
    expect(isCandidateWorkspaceTreePath('runs/run-2/engine/graph/workspaces/candidate-x/run.json')).toBe(true);
  });

  test('groups child attempts under the outer run without duplicate top-level cards', () => {
    const grouped = groupRunsByParent([
      {
        runId: 'outer',
        runKind: 'workflow',
        layoutVersion: 2,
        status: 'failed',
        task: 'parent task',
        artifactNamespace: 'demo',
        parent: null,
        stages: [],
        createdAt: null,
        updatedAt: null,
        endedAt: null,
        catalogPath: null,
      },
      {
        runId: 'child-a',
        runKind: 'plan',
        layoutVersion: 2,
        status: 'done',
        task: null,
        artifactNamespace: 'demo',
        parent: { runId: 'outer', stageId: 'build' },
        stages: [],
        createdAt: null,
        updatedAt: null,
        endedAt: null,
        catalogPath: null,
      },
    ]);
    expect(grouped).toHaveLength(1);
    expect(grouped[0]?.runId).toBe('outer');
    expect(grouped[0]?.children.map((c) => c.runId)).toEqual(['child-a']);
  });

  test('plan-run list nests children and detail exposes failed check navigation', async () => {
    const runId = 'run-nav-unit';
    const planKey = 'nav-unit';
    const attemptDir = join(workspaceRoot, 'runs', runId, 'stages', 'plan', 'attempts', runId);
    const childDir = join(workspaceRoot, 'runs', runId, 'stages', 'build', 'attempts', 'child-nav-unit');
    mkdirSync(attemptDir, { recursive: true });
    mkdirSync(childDir, { recursive: true });
    mkdirSync(join(workspaceRoot, 'artifacts', planKey), { recursive: true });
    writeFileSync(
      join(workspaceRoot, 'runs', runId, 'run.json'),
      JSON.stringify({
        kind: 'ralph_run_catalog',
        layoutVersion: 2,
        runKind: 'plan',
        runId,
        parent: null,
        status: 'failed',
        task: 'unit navigation',
        artifactNamespace: planKey,
        stages: [
          { stageId: 'plan', latestAttemptId: runId, status: 'failed' },
          { stageId: 'build', latestAttemptId: 'child-nav-unit', status: 'done' },
        ],
      }),
    );
    writeFileSync(
      join(attemptDir, 'run-manifest.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'ralph_run_manifest',
        run_id: runId,
        plan_key: planKey,
        status: 'failed',
        started_at: '2026-09-19T12:00:00Z',
        ended_at: '2026-09-19T12:01:00Z',
        parent: { workflow_run_id: null, graph_run_id: null, stage_id: null },
        paths: { artifacts_dir: `artifacts/${planKey}` },
        files: [{ path: `runs/${runId}/stages/plan/attempts/${runId}/failed-check.json`, role: 'verification', tier: 'run' }],
      }),
    );
    writeFileSync(
      join(attemptDir, 'failed-check.json'),
      JSON.stringify({
        command: 'npm test -- --runInBand unit-fail',
        output: 'FAIL unit-fail\nExpected pass',
        relatedArtifact: `artifacts/${planKey}/related.md`,
      }),
    );
    writeFileSync(join(workspaceRoot, 'artifacts', planKey, 'related.md'), '# related\n');
    writeFileSync(
      join(childDir, 'run-manifest.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'ralph_run_manifest',
        run_id: 'child-nav-unit',
        plan_key: planKey,
        status: 'done',
        started_at: '2026-09-19T12:00:30Z',
        ended_at: '2026-09-19T12:00:45Z',
        parent: { workflow_run_id: runId, graph_run_id: null, stage_id: 'build' },
        paths: { artifacts_dir: `artifacts/${planKey}` },
        files: [],
      }),
    );

    const listRes = createMockResponse();
    await handlePlanRunsListRequest(asReq({}, { planKey, workspaceRoot }), listRes);
    const listBody = listRes.body as { items: Array<{ runId: string; children?: Array<{ runId: string }> }> };
    expect(listBody.items.map((i) => i.runId)).toEqual([runId]);
    expect(listBody.items[0]?.children?.map((c) => c.runId)).toEqual(['child-nav-unit']);

    const detailRes = createMockResponse();
    await handlePlanRunDetailRequest(asReq({ runId }, { workspaceRoot }), detailRes);
    const detail = detailRes.body as {
      navigation: {
        task: string;
        status: string;
        failedChecks: Array<{ command: string; output: string; relatedArtifact: string | null }>;
      };
    };
    expect(detail.navigation.task).toBe('unit navigation');
    expect(detail.navigation.status).toBe('failed');
    expect(detail.navigation.failedChecks).toHaveLength(1);
    expect(detail.navigation.failedChecks[0]?.command).toContain('unit-fail');
    expect(detail.navigation.failedChecks[0]?.output).toContain('FAIL unit-fail');
    expect(detail.navigation.failedChecks[0]?.relatedArtifact).toBe(`artifacts/${planKey}/related.md`);

    const summary = buildRunNavigationSummary(workspaceRoot, runId);
    expect(summary?.failedChecks[0]?.command).toContain('unit-fail');
  });

  test('graph-run listing uses catalogs and does not surface decoy candidate trees', async () => {
    const runId = 'run-graph-nav';
    const ns = 'nav-graph';
    mkdirSync(join(workspaceRoot, 'runs', runId, 'engine', 'graph', 'nodes'), { recursive: true });
    mkdirSync(join(workspaceRoot, 'runs', runId, 'engine', 'graph', 'workspaces', 'candidate-decoy'), {
      recursive: true,
    });
    writeFileSync(
      join(workspaceRoot, 'runs', runId, 'run.json'),
      JSON.stringify({
        kind: 'ralph_run_catalog',
        layoutVersion: 2,
        runKind: 'graph',
        runId,
        status: 'succeeded',
        artifactNamespace: ns,
        parent: null,
        stages: [],
      }),
    );
    writeFileSync(
      join(workspaceRoot, 'runs', runId, 'engine', 'graph', 'run.json'),
      JSON.stringify({ runId, namespace: ns, status: 'succeeded', startedAt: '2026-09-19T12:00:00Z' }),
    );
    writeFileSync(
      join(workspaceRoot, 'runs', runId, 'engine', 'graph', 'nodes', 'n1.json'),
      JSON.stringify({ nodeId: 'n1', status: 'succeeded', attempts: [] }),
    );
    writeFileSync(
      join(workspaceRoot, 'runs', runId, 'engine', 'graph', 'workspaces', 'candidate-decoy', 'run.json'),
      JSON.stringify({ runId: 'decoy', namespace: ns, status: 'running' }),
    );

    const res = createMockResponse();
    await handleGraphRunsRequest(asReq({}, { workspaceRoot }) as Request, res as unknown as Response);
    const body = res.body as { runs: Array<{ runId: string; namespace: string }> };
    expect(body.runs).toEqual(
      expect.arrayContaining([expect.objectContaining({ runId, namespace: ns })]),
    );
    expect(body.runs.some((r) => r.runId === 'decoy')).toBe(false);
    expect(listNavigableRuns(workspaceRoot).some((r) => r.runId === 'decoy')).toBe(false);
  });
});
