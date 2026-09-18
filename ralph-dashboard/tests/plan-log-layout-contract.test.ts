import '@angular/compiler';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Request, Response } from 'express';

import { clearDashboardRootsCache, clearWorkspaceRootsCache } from '../src/paths';
import {
  clearMergedWorkspaceAllowlistCache,
  handleFileRequest,
  handlePlanRunDetailRequest,
  handlePlanRunsListRequest,
} from '../src/server/dashboard-api';
import { classifyFiles, FILE_ROLE_LABELS } from '../src/server/plan-run-detail';

const testDir = dirname(fileURLToPath(import.meta.url));

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

describe('plan log layout contract', () => {
  let tempRoot = '';
  let workspaceRoot = '';
  let originalWorkspacesFile: string | undefined;
  let originalDashboardWorkspaceRoot: string | undefined;
  let originalCwd: string | undefined;

  const MANIFEST_RUN_ID = 'run-20260101T000000Z-fixture';
  const LEGACY_RUN_ID = 'legacy-run-summary-1';

  beforeAll(() => {
    originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];
    originalDashboardWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
  });

  beforeEach(() => {
    clearMergedWorkspaceAllowlistCache();
    clearDashboardRootsCache();
    clearWorkspaceRootsCache();
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-plan-log-contract-'));
    process.chdir(tempRoot);
    workspaceRoot = join(tempRoot, '.ralph-workspace');
    mkdirSync(workspaceRoot, { recursive: true });
    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = tempRoot;
    process.env['RALPH_WORKSPACES_FILE'] = join(tempRoot, 'workspaces.json');
    writeFileSync(process.env['RALPH_WORKSPACES_FILE']!, '[]');

    writeManifestFixture();
    writeLegacyFlatOutputOnly();
    writeLegacyNestedSubdir();
    writeLegacyWithSummary();
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
  });

  function writeManifestFixture(): void {
    const planKey = 'manifest-fixture';
    const logDir = join(workspaceRoot, 'logs', planKey);
    const runDir = join(logDir, 'runs', MANIFEST_RUN_ID);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(
      join(runDir, 'run-manifest.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'ralph_run_manifest',
        run_id: MANIFEST_RUN_ID,
        plan_key: planKey,
        status: 'succeeded',
        started_at: '2026-01-01T00:00:00Z',
        ended_at: '2026-01-01T00:02:00Z',
        runtime: 'cursor',
        model: 'stub',
        files: [{ path: `logs/${planKey}/plan-usage-summary.json`, role: 'usage', tier: 'plan' }],
      }),
      'utf8',
    );
    writeFileSync(join(logDir, 'plan-usage-summary.json'), JSON.stringify({
      plan_key: planKey,
      run_id: MANIFEST_RUN_ID,
      status: 'succeeded',
      input_tokens: 3,
      output_tokens: 2,
      runtime: 'cursor',
      model: 'stub',
    }), 'utf8');
    writeFileSync(join(logDir, 'invocation-usage.json'), JSON.stringify({
      invocations: [{ run_id: MANIFEST_RUN_ID, ended_at: '2026-01-01T00:01:00Z', event: 'invocation' }],
    }), 'utf8');
    writeFileSync(join(logDir, 'plan-runner-demo-output.log'), 'manifest output line\n', 'utf8');
  }

  function writeLegacyFlatOutputOnly(): void {
    const logDir = join(workspaceRoot, 'logs', 'flat-output-only');
    mkdirSync(logDir, { recursive: true });
    writeFileSync(join(logDir, 'plan-runner-old-output.log'), 'legacy flat output\n', 'utf8');
  }

  function writeLegacyNestedSubdir(): void {
    const logDir = join(workspaceRoot, 'logs', 'nested-attempt', 'run-attempt-1');
    mkdirSync(logDir, { recursive: true });
    writeFileSync(join(logDir, 'plan-runner-nested-output.log'), 'nested output\n', 'utf8');
  }

  function writeLegacyWithSummary(): void {
    const planKey = 'summary-legacy';
    const logDir = join(workspaceRoot, 'logs', planKey);
    mkdirSync(logDir, { recursive: true });
    writeFileSync(join(logDir, 'plan-usage-summary.json'), JSON.stringify({
      plan_key: planKey,
      run_id: LEGACY_RUN_ID,
      status: 'legacy',
      started_at: '2025-11-01T00:00:00Z',
      input_tokens: 9,
      output_tokens: 4,
    }), 'utf8');
    writeFileSync(join(logDir, 'invocation-usage.json'), JSON.stringify({
      invocations: [{ run_id: LEGACY_RUN_ID, ended_at: '2025-11-01T00:00:30Z', event: 'invocation' }],
    }), 'utf8');
    writeFileSync(join(logDir, 'discover-report.json'), JSON.stringify({ aggregate_findings: [] }), 'utf8');
    writeFileSync(join(logDir, 'plan-runner-summary-output.log'), 'summary legacy output\n', 'utf8');
  }

  async function capture(handler: (req: Request, res: Response) => Promise<void>, req: Request): Promise<MockResponse> {
    const res = createMockResponse();
    await handler(req, res as unknown as Response);
    return res;
  }

  it('documents contract fields against manifest and legacy fixtures', async () => {
    const contractText = readFileSync(join(testDir, 'plan-log-layout-contract.md'), 'utf8');
    for (const token of ['PlanRunListItem', 'files.summary', 'source: "legacy"', 'workspaceRoot', 'processes/']) {
      expect(contractText).toContain(token);
    }
    for (const label of Object.values(FILE_ROLE_LABELS)) {
      expect(contractText).toContain(label);
    }

    const listed = await capture(handlePlanRunsListRequest, asReq({}, { workspaceRoot }));
    expect(listed.statusCode).toBe(200);
    const items = (listed.body as { items: Array<Record<string, unknown>> }).items;
    const manifest = items.find((item) => item['runId'] === MANIFEST_RUN_ID);
    const legacy = items.find((item) => item['runId'] === LEGACY_RUN_ID);
    expect(manifest).toMatchObject({
      planKey: 'manifest-fixture',
      source: 'manifest',
      status: 'succeeded',
      runtime: 'cursor',
    });
    expect(legacy).toMatchObject({
      planKey: 'summary-legacy',
      source: 'legacy',
      status: 'legacy',
    });
    expect(items.some((item) => item['planKey'] === 'flat-output-only' && item['runId'] === 'legacy-flat-output-only')).toBe(true);
    expect(items.some((item) => item['planKey'] === 'nested-attempt' && item['runId'] === 'legacy-nested-attempt')).toBe(true);

    const manifestDetail = await capture(
      handlePlanRunDetailRequest,
      asReq({ runId: MANIFEST_RUN_ID }, { workspaceRoot }),
    );
    expect(manifestDetail.statusCode).toBe(200);
    const manifestBody = manifestDetail.body as {
      files: {
        evidence: Array<{ path: string; label: string; target: { root: string; path: string } }>;
        summary: Array<{ path: string; label: string }>;
        raw: string[];
      };
      source: string;
      usage: { inputTokens: number };
    };
    expect(manifestBody.source).toBe('manifest');
    expect(manifestBody.files.evidence.length).toBeGreaterThan(0);
    expect(manifestBody.files.summary.map((f) => f.label)).toEqual(
      expect.arrayContaining(['Run manifest', 'Plan usage summary', 'Invocation usage history']),
    );
    expect(manifestBody.files.raw.some((p) => p.endsWith('plan-runner-demo-output.log'))).toBe(true);

    const legacyDetail = await capture(
      handlePlanRunDetailRequest,
      asReq({ runId: LEGACY_RUN_ID }, { workspaceRoot }),
    );
    expect(legacyDetail.statusCode).toBe(200);
    const legacyBody = legacyDetail.body as {
      files: { summary: Array<{ path: string; label: string }>; raw: string[] };
      source: string;
    };
    expect(legacyBody.source).toBe('legacy');
    expect(legacyBody.files.summary.some((f) => f.label === 'Plan usage summary')).toBe(true);
    expect(legacyBody.files.raw.some((p) => p.endsWith('discover-report.json'))).toBe(true);
    expect(legacyBody.files.raw.some((p) => p.includes('runs/'))).toBe(false);
  });

  it('evidence entries match FILE_ROLE_LABELS and every listed file is openable', async () => {
    const detail = await capture(
      handlePlanRunDetailRequest,
      asReq({ runId: MANIFEST_RUN_ID }, { workspaceRoot }),
    );
    const files = (detail.body as {
      files: {
        evidence: Array<{ path: string; target: { root: string; path: string } }>;
        summary: Array<{ path: string }>;
        raw: string[];
      };
    }).files;
    const allPaths = [...files.summary.map((f) => f.path), ...files.raw];
    const classified = classifyFiles(allPaths);
    expect(classified.summary.length).toBe(files.summary.length);
    expect(files.evidence.length).toBe(allPaths.length);

    for (const entry of files.evidence) {
      const fileRes = await capture(
        handleFileRequest,
        asReq({}, {
          root: entry.target.root,
          path: entry.target.path,
          workspaceRoot,
          offset: '0',
        }),
      );
      expect(fileRes.statusCode).toBe(200);
      expect(existsSync(join(workspaceRoot, entry.path))).toBe(true);
    }

    const flatOnlyPath = 'flat-output-only/plan-runner-old-output.log';
    const flatFile = await capture(
      handleFileRequest,
      asReq({}, { root: 'logs', path: flatOnlyPath, workspaceRoot, offset: '0' }),
    );
    expect(flatFile.statusCode).toBe(200);
  });
});
