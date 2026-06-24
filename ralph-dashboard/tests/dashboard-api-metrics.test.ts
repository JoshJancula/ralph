import '@angular/compiler';
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';

import { createInMemoryRequester } from './support/in-memory-request';
import { clearDashboardRootsCache } from '../src/paths';
import { clearMergedWorkspaceAllowlistCache } from '../src/server/dashboard-api';

describe('dashboard API metrics summary', () => {
  let tempRoot = '';
  let app: typeof import('../src/server').app;
  let originalWorkspaceRoot: string | undefined;
  let originalSkipListen: string | undefined;
  let originalDashboardGlobal: string | undefined;
  let originalProjectRoot: string | undefined;
  let originalRalphHome: string | undefined;
  let originalWorkspacesFile: string | undefined;
  let originalXdgConfigHome: string | undefined;
  let originalPlanWorkspaceRoot: string | undefined;
  let originalCwd: string | undefined;

  beforeAll(async () => {
    originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    originalDashboardGlobal = process.env['RALPH_DASHBOARD_GLOBAL'];
    originalProjectRoot = process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    originalRalphHome = process.env['RALPH_HOME'];
    originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];
    originalXdgConfigHome = process.env['XDG_CONFIG_HOME'];
    originalPlanWorkspaceRoot = process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
  });

  beforeEach(async () => {
    clearDashboardRootsCache();
    clearMergedWorkspaceAllowlistCache();
    originalCwd = process.cwd();
    tempRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-metrics-'));
    process.chdir(tempRoot);
    mkdirSync(join(tempRoot, '.ralph'), { recursive: true });
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
    process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = tempRoot;
    delete process.env['RALPH_DASHBOARD_GLOBAL'];
    delete process.env['RALPH_HOME'];
    delete process.env['RALPH_WORKSPACES_FILE'];
    delete process.env['XDG_CONFIG_HOME'];
    delete process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    ({ app } = await import('../src/server'));
  });

  afterEach(() => {
    if (originalCwd) {
      process.chdir(originalCwd);
    }
    clearDashboardRootsCache();
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

    if (originalDashboardGlobal === undefined) {
      delete process.env['RALPH_DASHBOARD_GLOBAL'];
    } else {
      process.env['RALPH_DASHBOARD_GLOBAL'] = originalDashboardGlobal;
    }
    if (originalProjectRoot === undefined) {
      delete process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    } else {
      process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = originalProjectRoot;
    }

    if (originalRalphHome === undefined) {
      delete process.env['RALPH_HOME'];
    } else {
      process.env['RALPH_HOME'] = originalRalphHome;
    }

    if (originalWorkspacesFile === undefined) {
      delete process.env['RALPH_WORKSPACES_FILE'];
    } else {
      process.env['RALPH_WORKSPACES_FILE'] = originalWorkspacesFile;
    }

    if (originalXdgConfigHome === undefined) {
      delete process.env['XDG_CONFIG_HOME'];
    } else {
      process.env['XDG_CONFIG_HOME'] = originalXdgConfigHome;
    }
    if (originalPlanWorkspaceRoot === undefined) {
      delete process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    } else {
      process.env['RALPH_PLAN_WORKSPACE_ROOT'] = originalPlanWorkspaceRoot;
    }
  });

  it('returns aggregated metrics summary data', async () => {
    const res = await createInMemoryRequester(app).get('/api/metrics/summary');

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      overall: {
        input_tokens: 40,
        output_tokens: 60,
        cache_creation_input_tokens: 4,
        cache_read_input_tokens: 6,
        elapsed_seconds: 13.5,
        count: 2,
        tool_calls_total: 0,
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

    const workspaceRoot = resolve(join(tempRoot, '.ralph-workspace'));
    expect(res.body.plans[0].workspace_root).toBe(workspaceRoot);
    expect(res.body.plans[0].project_root).toBe(resolve(tempRoot));
    expect(res.body.orchestrations[0].workspace_root).toBe(workspaceRoot);
    expect(Array.isArray(res.body.projects)).toBe(true);
    expect(res.body.projects).toHaveLength(1);
    expect(res.body.projects[0]).toMatchObject({
      workspace_root: workspaceRoot,
      project_root: resolve(tempRoot),
      label: basename(tempRoot),
      overall: {
        input_tokens: 40,
        output_tokens: 60,
        cache_creation_input_tokens: 4,
        cache_read_input_tokens: 6,
        elapsed_seconds: 13.5,
        count: 2,
        tool_calls_total: 0,
      },
    });
    expect(res.body.projects[0].plans).toHaveLength(1);
    expect(res.body.projects[0].orchestrations).toHaveLength(1);
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

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');

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

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
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
    const res = await createInMemoryRequester(app).get('/api/list?root=logs');
    expect(res.status).toBe(200);
    const names = (res.body.entries as Array<{ name: string }>).map((entry) => entry.name);
    expect(names).toEqual(expect.arrayContaining(['plan-1', 'plan-extra', 'orch-1']));
  });

  it('returns schema v2 savings report with session usage and counterfactual', async () => {
    const res = await createInMemoryRequester(app).get('/api/benchmarks?plan=plan-1');
    expect(res.status).toBe(200);
    expect(res.body.schema_version).toBe(2);
    expect(res.body.kind).toBe('ralph_benchmark_report');
    expect(res.body.session_usage).toMatchObject({
      input_tokens: 10,
      output_tokens: 20,
      cache_creation_input_tokens: 1,
      cache_read_input_tokens: 2,
      prompt_bytes: 0,
      tool_calls_total: 0,
    });
    expect(res.body.tool_output_counterfactual).toMatchObject({
      hypothetical_without_ralph_bytes: 0,
      actual_with_ralph_bytes: 0,
      net_savings_bytes: 0,
      net_savings_tokens: 0,
      net_savings_percent: 0,
    });
  });

  it('matches Python benchmark semantics for the shared parity fixture', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'dashboard-parity');
    mkdirSync(planDir, { recursive: true });
    const runtimeConfigDir = join(tempRoot, '.ralph-workspace', 'runtime-config', 'dashboard-parity');
    mkdirSync(runtimeConfigDir, { recursive: true });
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'dashboard-parity',
        artifact_ns: 'dashboard-parity',
        elapsed_seconds: 10,
        input_tokens: 800,
        output_tokens: 100,
        cache_creation_input_tokens: 50,
        cache_read_input_tokens: 150,
        prompt_bytes: 960,
        tool_calls_total: 24,
        compaction_measured_not_applied_bytes: 64,
        started_at: '2026-06-01T00:00:00Z',
        ended_at: '2026-06-01T00:10:00Z',
        byte_savings_by_path: {
          pre_tool_rewrite: {
            pre_optimization_bytes: 400,
            post_optimization_bytes: 200,
            saved_bytes: 200,
            pre_optimization_tokens: 100,
            post_optimization_tokens: 50,
            saved_tokens: 50,
            count: 1,
            token_cap_triggers: 0,
          },
          hook_compaction: {
            pre_optimization_bytes: 300,
            post_optimization_bytes: 200,
            saved_bytes: 100,
            pre_optimization_tokens: 75,
            post_optimization_tokens: 50,
            saved_tokens: 25,
            count: 1,
            token_cap_triggers: 0,
            hidden_from_context: 100,
            hidden_from_context_tokens: 25,
          },
          proxy_shell_compaction: {
            pre_optimization_bytes: 200,
            post_optimization_bytes: 120,
            saved_bytes: 80,
            pre_optimization_tokens: 50,
            post_optimization_tokens: 30,
            saved_tokens: 20,
            count: 1,
            token_cap_triggers: 0,
            hidden_from_context: 80,
            hidden_from_context_tokens: 20,
          },
          result_windowing: {
            pre_optimization_bytes: 1000,
            post_optimization_bytes: 200,
            saved_bytes: 800,
            pre_optimization_tokens: 250,
            post_optimization_tokens: 50,
            saved_tokens: 200,
            count: 1,
            token_cap_triggers: 0,
            hidden_from_context: 800,
            hidden_from_context_tokens: 200,
          },
        },
      }),
    );
    writeFileSync(
      join(runtimeConfigDir, 'result-windowing.jsonl'),
      [
        JSON.stringify({ event: 'envelope', resultId: 'r1', originalBytes: 1000, returnedBytes: 200, originalTokens: 250, returnedTokens: 50 }),
        JSON.stringify({ event: 'readback', resultId: 'r1', view: 'compacted', returnedBytes: 100, returnedTokens: 25 }),
        JSON.stringify({ event: 'readback', resultId: 'r1', view: 'raw', returnedBytes: 50, returnedTokens: 13 }),
      ].join('\n') + '\n',
    );

    const res = await createInMemoryRequester(app).get('/api/benchmarks?plan=dashboard-parity');
    expect(res.status).toBe(200);
    expect(res.body.schema_version).toBe(2);
    expect(res.body.run_count).toBe(1);
    expect(res.body.saved_bytes).toBe(1180);
    expect(res.body.session_usage).toMatchObject({
      input_tokens: 800,
      output_tokens: 100,
      cache_creation_input_tokens: 50,
      cache_read_input_tokens: 150,
      prompt_bytes: 960,
      tool_calls_total: 24,
    });
    const counterfactual = res.body.tool_output_counterfactual;
    expect(counterfactual.hypothetical_without_ralph_bytes).toBe(1900);
    expect(counterfactual.actual_with_ralph_bytes).toBe(720);
    expect(counterfactual.net_savings_bytes).toBe(1180);
    expect(counterfactual.net_savings_percent).toBe(62.1);
    expect(counterfactual.compaction_measured_not_applied_bytes).toBe(64);
    const readback = res.body.readback_summary;
    expect(readback.envelope_count).toBe(1);
    expect(readback.readback_count).toBe(2);
    expect(readback.gross_readback_bytes).toBe(150);
    expect(readback.net_consumed_bytes).toBe(350);
    expect(readback.effective_windowing_savings_rate).toBe(0.65);
  });

  it('keeps metrics local-first when a HOME workspace is also available', async () => {
    const homeRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-home-'));
    const homeWorkspace = join(homeRoot, 'shared-project');
    mkdirSync(join(homeWorkspace, '.ralph-workspace', 'logs', 'home-plan'), {
      recursive: true,
    });
    writeFileSync(
      join(homeWorkspace, '.ralph-workspace', 'logs', 'home-plan', 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'home-plan',
        artifact_ns: 'home-plan',
        elapsed_seconds: 9,
        input_tokens: 90,
        output_tokens: 9,
        cache_creation_input_tokens: 3,
        cache_read_input_tokens: 30,
        started_at: '2026-04-16T09:00:00.000Z',
      }),
    );

    const originalHome = process.env['HOME'];
    const originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    const originalPlanWorkspaceRoot = process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    const originalProjectRoot = process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    mkdirSync(join(tempRoot, '.ralph'), { recursive: true });
    process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = tempRoot;
    process.env['HOME'] = homeRoot;

    try {
      const res = await createInMemoryRequester(app).get('/api/metrics/summary');

      expect(res.status).toBe(200);
      expect(res.body.plans).toHaveLength(1);
      expect(res.body.plans[0]).toMatchObject({
        plan_key: 'plan-1',
        input_tokens: 10,
        output_tokens: 20,
      });
      expect(res.body.plans.map((plan: { plan_key: string }) => plan.plan_key)).not.toContain(
        'home-plan',
      );
    } finally {
      if (originalHome === undefined) {
        delete process.env['HOME'];
      } else {
        process.env['HOME'] = originalHome;
      }
      if (originalWorkspaceRoot === undefined) {
        delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
      } else {
        process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalWorkspaceRoot;
      }
      if (originalPlanWorkspaceRoot === undefined) {
        delete process.env['RALPH_PLAN_WORKSPACE_ROOT'];
      } else {
        process.env['RALPH_PLAN_WORKSPACE_ROOT'] = originalPlanWorkspaceRoot;
      }
      if (originalProjectRoot === undefined) {
        delete process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
      } else {
        process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = originalProjectRoot;
      }
    }
  });

  it('discovers HOME workspaces when no direct local workspace exists in full mode', async () => {
    const homeRoot = join(tempRoot, 'home-full');
    const homeWorkspace = join(homeRoot, 'shared-project');
    mkdirSync(join(homeWorkspace, '.ralph-workspace', 'logs', 'home-full-plan'), {
      recursive: true,
    });
    writeFileSync(
      join(
        homeWorkspace,
        '.ralph-workspace',
        'logs',
        'home-full-plan',
        'plan-usage-summary.json',
      ),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'home-full-plan',
        artifact_ns: 'home-full-plan',
        elapsed_seconds: 11,
        input_tokens: 33,
        output_tokens: 44,
        cache_creation_input_tokens: 5,
        cache_read_input_tokens: 12,
        started_at: '2026-04-16T09:30:00.000Z',
      }),
    );

    const noLocalCwd = join(tempRoot, 'no-local-cwd');
    mkdirSync(noLocalCwd, { recursive: true });
    const projectRoot = join(tempRoot, 'no-local-project');
    mkdirSync(join(projectRoot, '.ralph'), { recursive: true });

    const originalCwd = process.cwd();
    const originalHome = process.env['HOME'];
    const originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    const originalPlanWorkspaceRoot = process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    const originalFullMode = process.env['RALPH_DASHBOARD_FULL'];
    const originalProjectRoot = process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
    process.chdir(noLocalCwd);
    delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    delete process.env['RALPH_PLAN_WORKSPACE_ROOT'];
    process.env['HOME'] = homeRoot;
    process.env['RALPH_DASHBOARD_FULL'] = '1';
    process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = projectRoot;

    try {
      const res = await createInMemoryRequester(app).get('/api/metrics/summary');

      expect(res.status).toBe(200);
      expect(res.body.overall.count).toBe(1);
      expect(res.body.plans).toHaveLength(1);
      expect(res.body.plans[0]).toMatchObject({
        plan_key: 'home-full-plan',
        input_tokens: 33,
        output_tokens: 44,
      });
    } finally {
      process.chdir(originalCwd);
      if (originalHome === undefined) {
        delete process.env['HOME'];
      } else {
        process.env['HOME'] = originalHome;
      }
      if (originalWorkspaceRoot === undefined) {
        delete process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
      } else {
        process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'] = originalWorkspaceRoot;
      }
      if (originalPlanWorkspaceRoot === undefined) {
        delete process.env['RALPH_PLAN_WORKSPACE_ROOT'];
      } else {
        process.env['RALPH_PLAN_WORKSPACE_ROOT'] = originalPlanWorkspaceRoot;
      }
      if (originalFullMode === undefined) {
        delete process.env['RALPH_DASHBOARD_FULL'];
      } else {
        process.env['RALPH_DASHBOARD_FULL'] = originalFullMode;
      }
      if (originalProjectRoot === undefined) {
        delete process.env['RALPH_DASHBOARD_PROJECT_ROOT'];
      } else {
        process.env['RALPH_DASHBOARD_PROJECT_ROOT'] = originalProjectRoot;
      }
    }
  });

  it('omits the docs directory from top-level plans listings', async () => {
    mkdirSync(join(tempRoot, 'docs'), { recursive: true });
    const res = await createInMemoryRequester(app).get('/api/list?root=plans');
    expect(res.status).toBe(200);
    const names = (res.body.entries as Array<{ name: string }>).map((entry) => entry.name);
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

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
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

  it('recomputes stale nonzero totals from invocation-usage.json', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'plan-1');
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'plan-1',
        artifact_ns: 'plan-1',
        elapsed_seconds: 100,
        input_tokens: 1,
        output_tokens: 1,
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
            elapsed_seconds: 6,
            input_tokens: 5000,
            output_tokens: 200,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 10000,
          },
        ],
      }),
    );

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'plan-1');
    expect(plan.invocations).toBe(1);
    expect(plan.elapsed_seconds).toBe(6);
    expect(plan.input_tokens).toBe(5000);
    expect(plan.output_tokens).toBe(200);
    expect(plan.cache_read_input_tokens).toBe(10000);
    expect(plan.model_breakdown).toHaveLength(1);
  });

  it('returns distinct plan metrics when two workspaces share the same plan_key', async () => {
    const extraWorkspace = join(tempRoot, 'extra', '.ralph-workspace');
    const collisionDir = 'collision-plan';
    mkdirSync(join(tempRoot, '.ralph-workspace', 'logs', collisionDir), { recursive: true });
    mkdirSync(join(extraWorkspace, 'logs', collisionDir), { recursive: true });
    writeFileSync(
      join(tempRoot, '.ralph-workspace', 'logs', collisionDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'collision-plan',
        artifact_ns: 'collision-plan',
        elapsed_seconds: 3,
        input_tokens: 111,
        output_tokens: 1,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        started_at: '2026-04-16T12:00:00.000Z',
      }),
    );
    writeFileSync(
      join(extraWorkspace, 'logs', collisionDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'collision-plan',
        artifact_ns: 'collision-plan',
        elapsed_seconds: 4,
        input_tokens: 222,
        output_tokens: 2,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        started_at: '2026-04-16T12:30:00.000Z',
      }),
    );

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');

    expect(res.status).toBe(200);
    const dupPlans = res.body.plans.filter(
      (p: { plan_key: string }) => p.plan_key === 'collision-plan',
    );
    expect(dupPlans).toHaveLength(2);
    const wsRoots = dupPlans.map((p: { workspace_root: string }) => p.workspace_root);
    expect(new Set(wsRoots).size).toBe(2);
    const tokens = dupPlans.map((p: { input_tokens: number }) => p.input_tokens).sort((a, b) => a - b);
    expect(tokens).toEqual([111, 222]);

    const workspaceMain = resolve(join(tempRoot, '.ralph-workspace'));
    const workspaceExtra = resolve(extraWorkspace);
    expect(res.body.projects.some((p: { workspace_root: string }) => p.workspace_root === workspaceMain)).toBe(
      true,
    );
    expect(res.body.projects.some((p: { workspace_root: string }) => p.workspace_root === workspaceExtra)).toBe(
      true,
    );
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

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
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

  it('omits overlay metrics for legacy logs without overlay invocation fields', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'legacy-overlay');
    mkdirSync(planDir, { recursive: true });
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'legacy-overlay',
        artifact_ns: 'legacy-overlay',
        elapsed_seconds: 2,
        input_tokens: 10,
        output_tokens: 5,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
      }),
    );
    writeFileSync(
      join(planDir, 'invocation-usage.json'),
      JSON.stringify({
        invocations: [
          {
            runtime: 'claude',
            model: 'claude-sonnet',
            elapsed_seconds: 2,
            input_tokens: 10,
            output_tokens: 5,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
          },
        ],
      }),
    );

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'legacy-overlay');
    expect(plan).toBeDefined();
    expect(plan.overlay).toBeUndefined();
  });

  it('aggregates overlay metrics from invocation logs with overlay fields', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'overlay-plan');
    mkdirSync(planDir, { recursive: true });
    const summaryPath = join(planDir, 'plan-usage-summary.json');
    const usagePath = join(planDir, 'invocation-usage.json');
    writeFileSync(
      summaryPath,
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'overlay-plan',
        artifact_ns: 'overlay-plan',
        elapsed_seconds: 1,
        input_tokens: 1,
        output_tokens: 1,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
      }),
    );
    writeFileSync(
      usagePath,
      JSON.stringify({
        invocations: [
          {
            runtime: 'claude',
            model: 'claude-sonnet',
            elapsed_seconds: 4,
            input_tokens: 100,
            output_tokens: 20,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
            native_hooks_effective: true,
            mcp_effective: true,
            hook_compactions: 2,
            hook_rewrites: 1,
            hook_original_bytes: 1200,
            hook_compacted_bytes: 300,
            runtime_overlay_mode: 'bounded',
            runtime_overlay_warnings: ['hooks disabled for bare mode'],
          },
        ],
      }),
    );
    const now = Date.now() / 1000;
    utimesSync(summaryPath, now - 20, now - 20);
    utimesSync(usagePath, now, now);

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'overlay-plan');
    expect(plan).toBeDefined();
    expect(plan.input_tokens).toBe(100);
    expect(plan.overlay).toMatchObject({
      native_hooks_effective: true,
      mcp_effective: true,
      hook_compactions: 2,
      hook_rewrites: 1,
      hook_original_bytes: 1200,
      hook_compacted_bytes: 300,
      hook_bytes_saved: 900,
      runtime_overlay_mode: 'bounded',
      runtime_overlay_warnings: ['hooks disabled for bare mode'],
    });
  });

  it('keeps fresh summary totals when invocation log is older than plan-usage-summary', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'fresh-summary');
    mkdirSync(planDir, { recursive: true });
    const summaryPath = join(planDir, 'plan-usage-summary.json');
    const usagePath = join(planDir, 'invocation-usage.json');
    writeFileSync(
      usagePath,
      JSON.stringify({
        invocations: [
          {
            runtime: 'cursor',
            model: 'gpt-5.4-mini',
            elapsed_seconds: 1,
            input_tokens: 999,
            output_tokens: 1,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
            native_hooks_effective: false,
            mcp_effective: true,
            hook_compactions: 0,
            hook_rewrites: 0,
            hook_original_bytes: 0,
            hook_compacted_bytes: 0,
            runtime_overlay_mode: '',
            runtime_overlay_warnings: [],
          },
        ],
      }),
    );
    writeFileSync(
      summaryPath,
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'fresh-summary',
        artifact_ns: 'fresh-summary',
        elapsed_seconds: 5,
        input_tokens: 50,
        output_tokens: 10,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
      }),
    );
    const now = Date.now() / 1000;
    utimesSync(usagePath, now - 20, now - 20);
    utimesSync(summaryPath, now, now);

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'fresh-summary');
    expect(plan).toBeDefined();
    expect(plan.input_tokens).toBe(50);
    expect(plan.output_tokens).toBe(10);
    expect(plan.overlay).toMatchObject({
      mcp_effective: true,
      native_hooks_effective: false,
    });
  });

  it('aggregates mixed-runtime overlay metrics across model breakdown rows', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'mixed-overlay');
    mkdirSync(planDir, { recursive: true });
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'mixed-overlay',
        artifact_ns: 'mixed-overlay',
        elapsed_seconds: 0,
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
            runtime: 'claude',
            model: 'claude-sonnet',
            input_tokens: 40,
            output_tokens: 10,
            native_hooks_effective: true,
            mcp_effective: false,
            hook_compactions: 1,
            hook_rewrites: 0,
            hook_original_bytes: 500,
            hook_compacted_bytes: 100,
            runtime_overlay_mode: 'bounded',
            runtime_overlay_warnings: [],
          },
          {
            runtime: 'codex',
            model: 'gpt-5.4-mini',
            input_tokens: 60,
            output_tokens: 15,
            native_hooks_effective: false,
            mcp_effective: true,
            hook_compactions: 2,
            hook_rewrites: 1,
            hook_original_bytes: 800,
            hook_compacted_bytes: 200,
            runtime_overlay_mode: 'ralph',
            runtime_overlay_warnings: ['codex hook output mutation unsupported'],
          },
        ],
      }),
    );

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'mixed-overlay');
    expect(plan).toBeDefined();
    expect(plan.overlay).toMatchObject({
      native_hooks_effective: true,
      mcp_effective: true,
      hook_compactions: 3,
      hook_rewrites: 1,
      hook_original_bytes: 1300,
      hook_compacted_bytes: 300,
      hook_bytes_saved: 1000,
    });
    expect(plan.model_breakdown).toHaveLength(2);
    const claudeRow = plan.model_breakdown.find((row: { runtime: string }) => row.runtime === 'claude');
    const codexRow = plan.model_breakdown.find((row: { runtime: string }) => row.runtime === 'codex');
    expect(claudeRow?.overlay?.native_hooks_effective).toBe(true);
    expect(codexRow?.overlay?.mcp_effective).toBe(true);
    expect(codexRow?.overlay?.runtime_overlay_warnings).toEqual([
      'codex hook output mutation unsupported',
    ]);
  });

  it('includes overlay metrics for orchestration summaries with invocation logs', async () => {
    const orchDir = join(tempRoot, '.ralph-workspace', 'logs', 'orch-overlay');
    mkdirSync(orchDir, { recursive: true });
    writeFileSync(
      join(orchDir, 'orchestration-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'orchestration_usage_summary',
        plan_key: 'orch-overlay',
        artifact_ns: 'orch-overlay',
        elapsed_seconds: 3,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
      }),
    );
    writeFileSync(
      join(orchDir, 'invocation-usage.json'),
      JSON.stringify({
        invocations: [
          {
            runtime: 'opencode',
            model: 'glm-5',
            input_tokens: 30,
            output_tokens: 8,
            native_hooks_effective: true,
            mcp_effective: true,
            hook_compactions: 1,
            hook_rewrites: 0,
            hook_original_bytes: 200,
            hook_compacted_bytes: 50,
            runtime_overlay_mode: 'bounded',
            runtime_overlay_warnings: [],
          },
        ],
      }),
    );

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const orch = res.body.orchestrations.find((o: { plan_key: string }) => o.plan_key === 'orch-overlay');
    expect(orch).toBeDefined();
    expect(orch.overlay).toMatchObject({
      native_hooks_effective: true,
      mcp_effective: true,
      hook_compactions: 1,
      hook_bytes_saved: 150,
    });
  });

  it('omits tool call classification for legacy logs without accounting fields', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'legacy-tool-calls');
    mkdirSync(planDir, { recursive: true });
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'legacy-tool-calls',
        artifact_ns: 'legacy-tool-calls',
        elapsed_seconds: 2,
        input_tokens: 10,
        output_tokens: 5,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        tool_calls_total: 3,
      }),
    );
    writeFileSync(
      join(planDir, 'invocation-usage.json'),
      JSON.stringify({
        invocations: [
          {
            runtime: 'claude',
            model: 'claude-sonnet',
            elapsed_seconds: 2,
            input_tokens: 10,
            output_tokens: 5,
            tool_calls_total: 3,
          },
        ],
      }),
    );

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'legacy-tool-calls');
    expect(plan).toBeDefined();
    expect(plan.tool_calls).toBeUndefined();
    expect(plan.tool_calls_total).toBe(3);
  });

  it('aggregates tool call classification from invocation logs', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'classified-plan');
    mkdirSync(planDir, { recursive: true });
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'classified-plan',
        artifact_ns: 'classified-plan',
        elapsed_seconds: 0,
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
            runtime: 'claude',
            model: 'claude-sonnet',
            input_tokens: 40,
            output_tokens: 10,
            ralph_proxy_calls: 2,
            ralph_knowledge_calls: 0,
            native_read_compatibility_calls: 1,
            native_file_read_calls: 0,
            native_search_calls: 0,
            native_shell_calls: 0,
            ralph_mcp_calls: 2,
            native_read_like_calls: 1,
          },
          {
            runtime: 'claude',
            model: 'claude-sonnet',
            input_tokens: 30,
            output_tokens: 8,
            ralph_proxy_calls: 0,
            ralph_knowledge_calls: 3,
            native_shell_calls: 1,
            ralph_mcp_calls: 3,
            native_read_like_calls: 1,
          },
        ],
      }),
    );

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'classified-plan');
    expect(plan).toBeDefined();
    expect(plan.tool_calls).toMatchObject({
      ralph_proxy_calls: 2,
      ralph_knowledge_calls: 3,
      native_read_compatibility_calls: 1,
      native_shell_calls: 1,
      ralph_mcp_calls: 5,
    });
    expect(plan.model_breakdown).toHaveLength(1);
    expect(plan.model_breakdown[0].tool_calls).toMatchObject({
      ralph_proxy_calls: 2,
      ralph_knowledge_calls: 3,
      native_read_compatibility_calls: 1,
      native_shell_calls: 1,
    });
  });

  it('passes through tool call classification from summary model_breakdown', async () => {
    const planDir = join(tempRoot, '.ralph-workspace', 'logs', 'summary-breakdown-tools');
    mkdirSync(planDir, { recursive: true });
    writeFileSync(
      join(planDir, 'plan-usage-summary.json'),
      JSON.stringify({
        schema_version: 1,
        kind: 'plan_usage_summary',
        plan_key: 'summary-breakdown-tools',
        artifact_ns: 'summary-breakdown-tools',
        elapsed_seconds: 5,
        input_tokens: 50,
        output_tokens: 10,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        model_breakdown: [
          {
            runtime: 'cursor',
            model: 'gpt-5.4-mini',
            invocations: 2,
            elapsed_seconds: 5,
            input_tokens: 50,
            output_tokens: 10,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
            max_turn_total_tokens: 0,
            cache_hit_ratio: 0,
            ralph_proxy_calls: 4,
            ralph_knowledge_calls: 1,
            native_search_calls: 2,
            ralph_mcp_calls: 5,
            native_read_like_calls: 2,
          },
        ],
      }),
    );

    const res = await createInMemoryRequester(app).get('/api/metrics/summary');
    expect(res.status).toBe(200);
    const plan = res.body.plans.find((p: { plan_key: string }) => p.plan_key === 'summary-breakdown-tools');
    expect(plan).toBeDefined();
    expect(plan.tool_calls).toMatchObject({
      ralph_proxy_calls: 4,
      ralph_knowledge_calls: 1,
      native_search_calls: 2,
    });
    expect(plan.model_breakdown[0].tool_calls).toMatchObject({
      ralph_proxy_calls: 4,
      ralph_knowledge_calls: 1,
    });
  });
});
