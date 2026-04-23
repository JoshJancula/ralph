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
  let originalCwd: string | undefined;

  beforeAll(async () => {
    originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
  });

  beforeEach(async () => {
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-metrics-'));
    process.chdir(tempRoot);
    mkdirSync(join(tempRoot, '.ralph-workspace', 'logs', 'plan-1'), { recursive: true });
    mkdirSync(join(tempRoot, '.ralph-workspace', 'logs', 'orch-1'), { recursive: true });
    const extraWorkspace = join(tempRoot, 'extra', '.ralph-workspace');
    mkdirSync(join(extraWorkspace, 'logs', 'plan-extra'), { recursive: true });

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

  it('normalizes summaries even when kind metadata is missing', async () => {
    writeFileSync(
      join(tempRoot, '.ralph-workspace', 'logs', 'plan-1', 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        plan_key: 'plan-1',
        artifact_ns: 'plan-1',
        elapsed_seconds: 6,
        input_tokens: 7,
        output_tokens: 8,
        cache_creation_input_tokens: 1,
        cache_read_input_tokens: 2,
      }),
    );
    writeFileSync(
      join(tempRoot, '.ralph-workspace', 'logs', 'orch-1', 'orchestration-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        plan_key: 'orch-1',
        artifact_ns: 'orch-1',
        stage_id: 'build',
        elapsed_seconds: 9,
        input_tokens: 11,
        output_tokens: 13,
        cache_creation_input_tokens: 2,
        cache_read_input_tokens: 3,
      }),
    );

    const res = await request(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    expect(res.body.plans).toHaveLength(1);
    expect(res.body.plans[0]).toMatchObject({
      plan_key: 'plan-1',
      elapsed_seconds: 6,
      input_tokens: 7,
    });
    expect(res.body.orchestrations).toHaveLength(1);
  });

  it('aggregates log directories from nested workspaces', async () => {
    const res = await request(app).get('/api/list?root=logs');
    expect(res.status).toBe(200);
    const names = (res.body.entries as Array<{ name: string }>).map((entry) => entry.name);
    expect(names).toEqual(expect.arrayContaining(['plan-1', 'plan-extra', 'orch-1']));
  });

  it('omits the docs directory from top-level plans listings', async () => {
    mkdirSync(join(tempRoot, 'docs'), { recursive: true });
    writeFileSync(join(tempRoot, 'plan-sample.md'), '# sample plan');

    const res = await request(app).get('/api/list?root=plans');
    expect(res.status).toBe(200);
    const names = (res.body.entries as Array<{ name: string }>).map((entry) => entry.name);

    expect(names.some((name) => name.toLowerCase().startsWith('plan') && name.toLowerCase().endsWith('.md'))).toBe(true);
    expect(names).not.toContain('docs');
  });

  it('attaches model_breakdown from invocation-usage.json without overwriting non-zero totals', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'plan-1');
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'plan-1',
        artifact_ns: 'plan-1',
        runtime: 'cursor',
        model: 'gpt-5.4-mini-medium',
        elapsed_seconds: 1462,
        input_tokens: 721262,
        output_tokens: 57488,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 15280640,
        max_turn_total_tokens: 0,
        cache_hit_ratio: 0.9549,
        started_at: '2026-04-17T05:18:52Z',
      }),
    );
    writeFileSync(
      join(planDir, 'invocation-usage.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_invocation_usage_history',
        invocations: [
          {
            iteration: 1,
            runtime: 'opencode',
            model: 'ollama-cloud/glm-5.1',
            elapsed_seconds: 56,
            input_tokens: 71195,
            output_tokens: 663,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
          },
          {
            iteration: 1,
            runtime: 'cursor',
            model: 'gpt-5.4-mini-medium',
            elapsed_seconds: 200,
            input_tokens: 650067,
            output_tokens: 56825,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 15280640,
          },
        ],
      }),
    );

    const res = await request(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'plan-1');
    expect(plan).toBeDefined();
    expect(plan.input_tokens).toBe(721262);
    expect(plan.output_tokens).toBe(57488);
    expect(plan.cache_read_input_tokens).toBe(15280640);
    expect(plan.cache_hit_ratio).toBe(0.9549);
    expect(Array.isArray(plan.model_breakdown)).toBe(true);
    expect(plan.model_breakdown).toHaveLength(2);
    const runtimes = plan.model_breakdown.map((m: { runtime: string }) => m.runtime).sort();
    expect(runtimes).toEqual(['cursor', 'opencode']);
  });

  it('recomputes totals from invocation-usage.json only when summary tokens are all zero', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'plan-1');
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'plan-1',
        artifact_ns: 'plan-1',
        elapsed_seconds: 100,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
      }),
    );
    writeFileSync(
      join(planDir, 'invocation-usage.json'),
      JSON.stringify({
        invocations: [
          {
            runtime: 'codex',
            model: 'gpt-5.4-mini',
            input_tokens: 5000,
            output_tokens: 200,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 10000,
          },
        ],
      }),
    );

    const res = await request(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'plan-1');
    expect(plan.input_tokens).toBe(5000);
    expect(plan.output_tokens).toBe(200);
    expect(plan.cache_read_input_tokens).toBe(10000);
    expect(plan.model_breakdown).toHaveLength(1);
  });

  it('uses peak max_turn_total_tokens (not sum) when deriving model breakdown from invocations', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'plan-1');
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'plan-1',
        artifact_ns: 'plan-1',
        elapsed_seconds: 100,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
      }),
    );
    writeFileSync(
      join(planDir, 'invocation-usage.json'),
      JSON.stringify({
        invocations: [
          {
            runtime: 'codex',
            model: 'gpt-5.4-mini',
            input_tokens: 2000,
            output_tokens: 120,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 4000,
            max_turn_total_tokens: 300,
          },
          {
            runtime: 'codex',
            model: 'gpt-5.4-mini',
            input_tokens: 1800,
            output_tokens: 110,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 3900,
            max_turn_total_tokens: 700,
          },
        ],
      }),
    );

    const res = await request(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'plan-1');
    expect(plan).toBeDefined();
    expect(plan.max_turn_total_tokens).toBe(700);
    expect(plan.model_breakdown).toHaveLength(1);
    expect(plan.model_breakdown[0]).toMatchObject({
      runtime: 'codex',
      model: 'gpt-5.4-mini',
      max_turn_total_tokens: 700,
    });
  });
});
