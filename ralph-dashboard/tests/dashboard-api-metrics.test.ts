import '@angular/compiler';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';

import { createInMemoryRequester } from './support/in-memory-request';
import { clearMergedWorkspaceAllowlistCache } from '../src/server/dashboard-api';

describe('dashboard API metrics summary', () => {
  let tempRoot = '';
  let app: typeof import('../src/server').app;
  let originalWorkspaceRoot: string | undefined;
  let originalSkipListen: string | undefined;
  let originalDashboardGlobal: string | undefined;
  let originalRalphHome: string | undefined;
  let originalWorkspacesFile: string | undefined;
  let originalXdgConfigHome: string | undefined;
  let originalCwd: string | undefined;

  beforeAll(async () => {
    originalWorkspaceRoot = process.env['RALPH_DASHBOARD_WORKSPACE_ROOT'];
    originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    originalDashboardGlobal = process.env['RALPH_DASHBOARD_GLOBAL'];
    originalRalphHome = process.env['RALPH_HOME'];
    originalWorkspacesFile = process.env['RALPH_WORKSPACES_FILE'];
    originalXdgConfigHome = process.env['XDG_CONFIG_HOME'];
    process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
  });

  beforeEach(async () => {
    clearMergedWorkspaceAllowlistCache();
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
    delete process.env['RALPH_DASHBOARD_GLOBAL'];
    delete process.env['RALPH_HOME'];
    delete process.env['RALPH_WORKSPACES_FILE'];
    delete process.env['XDG_CONFIG_HOME'];
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

    if (originalDashboardGlobal === undefined) {
      delete process.env['RALPH_DASHBOARD_GLOBAL'];
    } else {
      process.env['RALPH_DASHBOARD_GLOBAL'] = originalDashboardGlobal;
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
    writeFileSync(join(tempRoot, 'plan-sample.md'), '# sample plan');

    const res = await createInMemoryRequester(app).get('/api/list?root=plans');
    expect(res.status).toBe(200);
    const names = (res.body.entries as Array<{ name: string }>).map((entry) => entry.name);

    expect(
      names.some(
        (name) => name.toLowerCase().startsWith('plan') && name.toLowerCase().endsWith('.md'),
      ),
    ).toBe(true);
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
});
