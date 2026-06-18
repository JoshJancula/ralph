import '@angular/compiler';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { createInMemoryRequester } from './support/in-memory-request';
import { clearMergedWorkspaceAllowlistCache } from '../src/server/dashboard-api';

describe('dashboard API discover report', () => {
  let tempRoot = '';
  let app: typeof import('../src/server').app;
  let originalWorkspaceRoot: string | undefined;
  let originalSkipListen: string | undefined;
  let originalCwd: string | undefined;

  beforeAll(async () => {
    originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
  });

  beforeEach(async () => {
    clearMergedWorkspaceAllowlistCache();
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-discover-'));
    process.chdir(tempRoot);
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'plan-discover');
    mkdirSync(planDir, { recursive: true });
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'plan-discover',
        artifact_ns: 'plan-discover',
        elapsed_seconds: 1,
        input_tokens: 100,
        output_tokens: 50,
      }),
    );
    writeFileSync(
      join(planDir, 'discover-report.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'discover_report',
        plan_key: 'plan-discover',
        sequence_patterns: [{ pattern_id: 'native_read_after_grep', count: 1 }],
        limitations: ['whole_file_reads: not available without sanitized tool arguments'],
      }),
    );
    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = tempRoot;
    ({ app } = await import('../src/server'));
  });

  afterEach(() => {
    if (originalCwd) {
      process.chdir(originalCwd);
    }
    if (tempRoot) {
      rmSync(tempRoot, { recursive: true, force: true });
    }
  });

  afterAll(() => {
    if (originalWorkspaceRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalWorkspaceRoot;
    }
    if (originalSkipListen === undefined) {
      delete process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    } else {
      process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = originalSkipListen;
    }
  });

  it('returns discover report for a plan key', async () => {
    const res = await createInMemoryRequester(app).get('/api/metrics/discover/plan-discover');

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      plan_key: 'plan-discover',
      report: {
        kind: 'discover_report',
        sequence_patterns: [{ pattern_id: 'native_read_after_grep', count: 1 }],
      },
    });
    expect(res.body.report.limitations[0]).toContain('whole_file_reads');
  });

  it('returns 404 when discover report is missing', async () => {
    const res = await createInMemoryRequester(app).get('/api/metrics/discover/missing-plan');

    expect(res.status).toBe(404);
  });

  it('rejects invalid plan keys', async () => {
    const res = await createInMemoryRequester(app).get('/api/metrics/discover/foo%2Fbar');

    expect(res.status).toBe(400);
  });
});
