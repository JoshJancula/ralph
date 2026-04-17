import '@angular/compiler';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import request from 'supertest';

describe('dashboard API metrics summary', () => {
  let tempRoot = '';
  let app: typeof import('../src/server').app;
  let originalWorkspaceRoot: string | undefined;
  let originalSkipListen: string | undefined;

  beforeAll(async () => {
    originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
  });

  beforeEach(async () => {
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-metrics-'));
    mkdirSync(join(tempRoot, '.ralph-workspace', 'logs', 'plan-1'), { recursive: true });
    mkdirSync(join(tempRoot, '.ralph-workspace', 'logs', 'orch-1'), { recursive: true });

    writeFileSync(
      join(tempRoot, '.ralph-workspace', 'logs', 'plan-1', 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'plan-1',
        artifact_ns: 'plan-1',
        elapsed_seconds: 5,
        input_tokens: 10,
        output_tokens: 20,
        cache_creation_input_tokens: 1,
        cache_read_input_tokens: 2,
        started_at: '2026-04-16T10:00:00.000Z',
      }),
    );
    writeFileSync(
      join(tempRoot, '.ralph-workspace', 'logs', 'orch-1', 'orchestration-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'orchestration_usage_summary',
        plan_key: 'orch-1',
        artifact_ns: 'orch-1',
        stage_id: 'build',
        elapsed_seconds: 8.5,
        input_tokens: 30,
        output_tokens: 40,
        cache_creation_input_tokens: 3,
        cache_read_input_tokens: 4,
        started_at: '2026-04-16T11:00:00.000Z',
      }),
    );
    writeFileSync(join(tempRoot, '.ralph-workspace', 'logs', 'ignored.txt'), 'ignore me');

    process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = tempRoot;
    ({ app } = await import('../src/server'));
  });

  afterEach(() => {
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

  it('returns aggregated metrics summary data', async () => {
    const res = await request(app).get('/api/metrics/summary');

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      overall: {
        input_tokens: 40,
        output_tokens: 60,
        cache_creation_input_tokens: 4,
        cache_read_input_tokens: 6,
        elapsed_seconds: 13.5,
        count: 2,
      },
    });
    expect(res.body.plans).toHaveLength(1);
    expect(res.body.orchestrations).toHaveLength(1);
    expect(res.body.plans[0]).toMatchObject({
      plan_key: 'plan-1',
      artifact_ns: 'plan-1',
      elapsed_seconds: 5,
      input_tokens: 10,
      output_tokens: 20,
    });
    expect(res.body.orchestrations[0]).toMatchObject({
      plan_key: 'orch-1',
      artifact_ns: 'orch-1',
      stage_id: 'build',
      elapsed_seconds: 8.5,
      input_tokens: 30,
      output_tokens: 40,
    });
  });

  it('surfaces max_turn_total_tokens and cache_hit_ratio from summary files', async () => {
    // Overwrite plan-1 summary with new fields.
    writeFileSync(
      join(tempRoot, '.ralph-workspace', 'logs', 'plan-1', 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'plan-1',
        artifact_ns: 'plan-1',
        elapsed_seconds: 5,
        input_tokens: 100,
        output_tokens: 20,
        cache_creation_input_tokens: 10,
        cache_read_input_tokens: 40,
        max_turn_total_tokens: 55000,
        cache_hit_ratio: 0.267,
        started_at: '2026-04-16T10:00:00.000Z',
      }),
    );

    const res = await request(app).get('/api/metrics/summary');

    expect(res.status).toBe(200);
    expect(res.body.plans[0]).toMatchObject({
      plan_key: 'plan-1',
      max_turn_total_tokens: 55000,
      cache_hit_ratio: 0.267,
    });
    // overall.max_turn_total_tokens should be the max across all items.
    expect(res.body.overall.max_turn_total_tokens).toBe(55000);
    // overall.cache_hit_ratio is derived from accumulated token totals.
    expect(typeof res.body.overall.cache_hit_ratio).toBe('number');
  });
});
