import '@angular/compiler';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Request, Response } from 'express';

import { clearDashboardRootsCache, clearWorkspaceRootsCache } from '../src/paths';
import {
  clearMergedWorkspaceAllowlistCache,
  handleFileRequest,
  handleGraphRunDetailRequest,
  handleListRequest,
  handlePlanRunDetailRequest,
  handlePlanRunFilesRequest,
  handlePlanRunsListRequest,
} from '../src/server/dashboard-api';

const SECRET_PROCESS_TOKEN = 'PROCESS_RUN_TOKEN_MUST_NOT_LEAK';

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

function asReq(params: Record<string, string>, query: Record<string, string> = {}): Request {
  return { params, query } as unknown as Request;
}

describe('plan-run routes and explorer roots', () => {
  let tempRoot = '';
  let workspaceRoot = '';
  let originalWorkspacesFile: string | undefined;
  let originalDashboardWorkspaceRoot: string | undefined;
  let originalDashboardGlobal: string | undefined;
  let originalCwd: string | undefined;
  const capturedBodies: unknown[] = [];

  beforeAll(() => {
    originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];
    originalDashboardWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalDashboardGlobal = process.env['RALPH_DASHBOARD_GLOBAL'];
  });

  beforeEach(() => {
    capturedBodies.length = 0;
    clearMergedWorkspaceAllowlistCache();
    clearDashboardRootsCache();
    clearWorkspaceRootsCache();
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-plan-runs-'));
    process.chdir(tempRoot);
    workspaceRoot = join(tempRoot, '.ralph-workspace');
    mkdirSync(workspaceRoot, { recursive: true });
    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = tempRoot;
    process.env['RALPH_WORKSPACES_FILE'] = join(tempRoot, 'workspaces.json');
    delete process.env['RALPH_DASHBOARD_GLOBAL'];
    writeFileSync(process.env['RALPH_WORKSPACES_FILE']!, '[]');

    const planKey = 'demo-plan';
    const runId = 'run-20260101T000000Z-demo';
    const logDir = join(workspaceRoot, 'logs', planKey);
    const runDir = join(logDir, 'runs', runId);
    mkdirSync(runDir, { recursive: true });
    mkdirSync(join(workspaceRoot, 'graph-runs'), { recursive: true });
    mkdirSync(join(workspaceRoot, 'processes', runId), { recursive: true });
    writeFileSync(
      join(workspaceRoot, 'processes', runId, 'run.json'),
      JSON.stringify({ run_id: runId, token: SECRET_PROCESS_TOKEN, status: 'running' }),
      'utf8',
    );
    writeFileSync(
      join(runDir, 'run-manifest.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'ralph_run_manifest',
        run_id: runId,
        plan_key: planKey,
        status: 'succeeded',
        started_at: '2026-01-01T00:00:00Z',
        ended_at: '2026-01-01T00:01:00Z',
        files: [{ path: `logs/${planKey}/plan-usage-summary.json`, role: 'usage', tier: 'plan' }],
        paths: { process_run_dir: `processes/${runId}` },
      }),
      'utf8',
    );
    writeFileSync(
      join(logDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 2,
        kind: 'plan_usage_summary',
        plan_key: planKey,
        run_id: runId,
        status: 'succeeded',
        started_at: '2026-01-01T00:00:00Z',
        ended_at: '2026-01-01T00:01:00Z',
        input_tokens: 1,
        output_tokens: 1,
      }),
      'utf8',
    );
    writeFileSync(
      join(logDir, 'invocation-usage.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_invocation_usage_history',
        invocations: [{ iteration: 1, run_id: runId, ended_at: '2026-01-01T00:00:30Z', event: 'invocation' }],
      }),
      'utf8',
    );

    const graphNs = 'demo-ns';
    const graphRunId = 'run-20260102T000000Z-graph';
    const graphRunDir = join(workspaceRoot, 'graph-runs', graphNs, graphRunId);
    mkdirSync(join(graphRunDir, 'nodes'), { recursive: true });
    writeFileSync(join(graphRunDir, 'run.json'), JSON.stringify({ runId: graphRunId, startedAt: '2026-01-02T00:00:00Z', status: 'succeeded' }), 'utf8');
    writeFileSync(join(graphRunDir, 'graph.json'), JSON.stringify({ nodes: [] }), 'utf8');
    writeFileSync(join(graphRunDir, 'observability.jsonl'), `${JSON.stringify({ event: 'admission', timestamp: '2026-01-02T00:00:01Z' })}\n`, 'utf8');
    writeFileSync(join(graphRunDir, 'nodes', 'implement.json'), JSON.stringify({ nodeId: 'implement', status: 'succeeded', attempts: [] }), 'utf8');

    const legacyDir = join(workspaceRoot, 'logs', 'legacy-plan');
    mkdirSync(legacyDir, { recursive: true });
    writeFileSync(
      join(legacyDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 2,
        kind: 'plan_usage_summary',
        plan_key: 'legacy-plan',
        run_id: 'legacy-run-1',
        status: 'legacy',
        started_at: '2025-12-01T00:00:00Z',
      }),
      'utf8',
    );
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

  async function capture(handler: (req: Request, res: Response) => Promise<void>, req: Request): Promise<MockResponse> {
    const res = createMockResponse();
    await handler(req, res as unknown as Response);
    capturedBodies.push(res.body);
    return res;
  }

  it('lists manifest and legacy plan runs and returns 200', async () => {
    const listed = await capture(handlePlanRunsListRequest, asReq({}, { planKey: 'demo-plan', workspaceRoot }));
    expect(listed.statusCode).toBe(200);
    const items = (listed.body as { items: Array<{ runId: string }> }).items;
    expect(items.map((item) => item.runId)).toContain('run-20260101T000000Z-demo');

    const all = await capture(handlePlanRunsListRequest, asReq({}, { workspaceRoot }));
    expect(all.statusCode).toBe(200);
    const allIds = (all.body as { items: Array<{ runId: string; source: string }> }).items;
    expect(allIds.some((item) => item.runId === 'legacy-run-1' && item.source === 'legacy')).toBe(true);
  });

  it('returns enriched plan-run detail and files for a real run, 404 for unknown', async () => {
    const detail = await capture(
      handlePlanRunDetailRequest,
      asReq({ runId: 'run-20260101T000000Z-demo' }, { workspaceRoot }),
    );
    expect(detail.statusCode).toBe(200);
    const body = detail.body as { runId: string; files: { summary: unknown[]; raw: unknown[] }; operatorNext: unknown };
    expect(body.runId).toBe('run-20260101T000000Z-demo');
    expect(Array.isArray(body.files.summary)).toBe(true);
    expect(body.operatorNext).toBeTruthy();

    const files = await capture(
      handlePlanRunFilesRequest,
      asReq({ runId: 'run-20260101T000000Z-demo' }, { workspaceRoot }),
    );
    expect(files.statusCode).toBe(200);
    expect((files.body as { summary: unknown[] }).summary.length).toBeGreaterThan(0);

    const missing = await capture(
      handlePlanRunDetailRequest,
      asReq({ runId: 'run-does-not-exist' }, { workspaceRoot }),
    );
    expect(missing.statusCode).toBe(404);

    const missingFiles = await capture(
      handlePlanRunFilesRequest,
      asReq({ runId: 'run-does-not-exist' }, { workspaceRoot }),
    );
    expect(missingFiles.statusCode).toBe(404);
  });

  it('returns graph-run detail 200 for a real run and 404 for unknown', async () => {
    const detail = await capture(
      handleGraphRunDetailRequest,
      asReq({ namespace: 'demo-ns', runId: 'run-20260102T000000Z-graph' }, { workspaceRoot }),
    );
    expect(detail.statusCode).toBe(200);
    const body = detail.body as { files: { summary: unknown[] }; timeline: unknown[] };
    expect(body.files.summary.length).toBeGreaterThan(0);
    expect(Array.isArray(body.timeline)).toBe(true);

    const missing = await capture(
      handleGraphRunDetailRequest,
      asReq({ namespace: 'demo-ns', runId: 'missing-run' }, { workspaceRoot }),
    );
    expect(missing.statusCode).toBe(404);
  });

  it('lists graph-runs without unknown root', async () => {
    const res = await capture(handleListRequest, asReq({}, { root: 'graph-runs', workspaceRoot }));
    expect(JSON.stringify(res.body)).not.toContain('unknown root');
    expect(res.statusCode).toBe(200);
  });

  it('does not expose processes run.json token on any endpoint', async () => {
    await capture(handlePlanRunsListRequest, asReq({}, { workspaceRoot }));
    await capture(handlePlanRunDetailRequest, asReq({ runId: 'run-20260101T000000Z-demo' }, { workspaceRoot }));
    await capture(handlePlanRunFilesRequest, asReq({ runId: 'run-20260101T000000Z-demo' }, { workspaceRoot }));
    await capture(
      handleGraphRunDetailRequest,
      asReq({ namespace: 'demo-ns', runId: 'run-20260102T000000Z-graph' }, { workspaceRoot }),
    );
    await capture(handleListRequest, asReq({}, { root: 'graph-runs', workspaceRoot }));
    const processesList = await capture(handleListRequest, asReq({}, { root: 'processes', workspaceRoot }));
    expect(processesList.statusCode).toBe(400);
    expect(JSON.stringify(processesList.body)).toContain('unknown root');

    const leaked = capturedBodies.some((body) => JSON.stringify(body).includes(SECRET_PROCESS_TOKEN));
    expect(leaked).toBe(false);
    const tokenKeyFromProcess = capturedBodies.some((body) => {
      const text = JSON.stringify(body);
      return text.includes(SECRET_PROCESS_TOKEN) || /"token"\s*:/.test(text);
    });
    expect(tokenKeyFromProcess).toBe(false);
  });

  it('returns typed evidence for manifest and legacy fixture shapes', async () => {
    const flatDir = join(workspaceRoot, 'logs', 'flat-output-only');
    mkdirSync(flatDir, { recursive: true });
    writeFileSync(join(flatDir, 'plan-runner-only-output.log'), 'only output\n', 'utf8');

    const nestedDir = join(workspaceRoot, 'logs', 'nested-attempt', 'run-attempt-1');
    mkdirSync(nestedDir, { recursive: true });
    writeFileSync(join(nestedDir, 'plan-runner-nested-output.log'), 'nested\n', 'utf8');

    const listed = await capture(handlePlanRunsListRequest, asReq({}, { workspaceRoot }));
    const items = (listed.body as { items: Array<{ runId: string; planKey: string; source: string }> }).items;
    expect(items.some((item) => item.runId === 'run-20260101T000000Z-demo' && item.source === 'manifest')).toBe(true);
    expect(items.some((item) => item.runId === 'legacy-run-1' && item.source === 'legacy')).toBe(true);
    expect(items.some((item) => item.runId === 'legacy-flat-output-only')).toBe(true);
    expect(items.some((item) => item.runId === 'legacy-nested-attempt')).toBe(true);

    const manifestDetail = await capture(
      handlePlanRunDetailRequest,
      asReq({ runId: 'run-20260101T000000Z-demo' }, { workspaceRoot }),
    );
    const manifestFiles = (manifestDetail.body as {
      files: {
        evidence: Array<{ category: string; target: { root: string; path: string }; sizeBytes: number | null }>;
      };
    }).files;
    expect(manifestFiles.evidence.length).toBeGreaterThan(0);
    expect(manifestFiles.evidence.every((entry) => entry.target.root && entry.target.path)).toBe(true);
    expect(manifestFiles.evidence.some((entry) => entry.category === 'run-metadata')).toBe(true);

    const nestedDetail = await capture(
      handlePlanRunDetailRequest,
      asReq({ runId: 'legacy-nested-attempt' }, { workspaceRoot }),
    );
    const nestedEvidence = (nestedDetail.body as {
      files: { evidence: Array<{ path: string; category: string }> };
    }).files.evidence;
    expect(nestedEvidence.some((entry) => entry.path.includes('run-attempt-1'))).toBe(true);
    expect(nestedEvidence.some((entry) => entry.category === 'execution-output')).toBe(true);

    for (const entry of manifestFiles.evidence) {
      const read = await capture(
        handleFileRequest,
        asReq({}, { root: entry.target.root, path: entry.target.path, workspaceRoot, offset: '0' }),
      );
      expect(read.statusCode).toBe(200);
    }
  });

  it('rejects malformed run ids and strips unsafe manifest paths', async () => {
    const bad = await capture(handlePlanRunDetailRequest, asReq({ runId: '../evil' }, { workspaceRoot }));
    expect(bad.statusCode).toBe(400);

    const runDir = join(workspaceRoot, 'logs', 'demo-plan', 'runs', 'run-20260101T000000Z-demo');
    writeFileSync(
      join(runDir, 'run-manifest.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'ralph_run_manifest',
        run_id: 'run-20260101T000000Z-demo',
        plan_key: 'demo-plan',
        status: 'succeeded',
        files: [
          { path: `processes/run-20260101T000000Z-demo/run.json`, role: 'secret', tier: 'process' },
          { path: '../../../../../etc/passwd', role: 'escape', tier: 'bad' },
          { path: `logs/demo-plan/plan-usage-summary.json`, role: 'usage', tier: 'plan' },
        ],
      }),
      'utf8',
    );

    const detail = await capture(
      handlePlanRunDetailRequest,
      asReq({ runId: 'run-20260101T000000Z-demo' }, { workspaceRoot }),
    );
    const evidence = (detail.body as { files: { evidence: Array<{ path: string }> } }).files.evidence;
    expect(JSON.stringify(evidence)).not.toContain('passwd');
    expect(JSON.stringify(evidence)).not.toContain('processes/');
    expect(evidence.some((entry) => entry.path.endsWith('plan-usage-summary.json'))).toBe(true);
  });

  it('returns empty list for missing workspace root without throwing', async () => {
    const missing = await capture(
      handlePlanRunsListRequest,
      asReq({}, { workspaceRoot: join(tempRoot, 'no-such-workspace') }),
    );
    expect(missing.statusCode).toBe(200);
    expect((missing.body as { items: unknown[] }).items).toEqual([]);
  });

  it('files endpoint returns evidence model', async () => {
    const files = await capture(
      handlePlanRunFilesRequest,
      asReq({ runId: 'run-20260101T000000Z-demo' }, { workspaceRoot }),
    );
    expect(files.statusCode).toBe(200);
    const body = files.body as { evidence: unknown[]; summary: unknown[]; raw: string[] };
    expect(Array.isArray(body.evidence)).toBe(true);
    expect(body.evidence.length).toBe(body.summary.length + body.raw.length);
  });
});
