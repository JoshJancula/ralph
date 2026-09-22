import { buildMetricsBreakdown, type InsightsRunItem } from './metrics-insights';

function runItem(overrides: Partial<InsightsRunItem> = {}): InsightsRunItem {
  return {
    path: '/logs/plan-1/plan-usage-summary.json',
    plan_key: 'plan-1',
    kind: 'plan',
    workspace_root: '/ws',
    project_root: '/proj',
    runtime: 'claude',
    model: 'claude-opus-5',
    started_at: '2026-04-16T09:00:00.000Z',
    elapsed_seconds: 10,
    input_tokens: 120,
    output_tokens: 80,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 220,
    max_turn_total_tokens: 900,
    cache_hit_ratio: 0.64,
    tool_calls_total: 8,
    ...overrides,
  };
}

describe('buildMetricsBreakdown run rows', () => {
  it('reports every model used in a run, ordered by total tokens', () => {
    const breakdown = buildMetricsBreakdown([
      runItem({
        model_breakdown: [
          {
            runtime: 'claude',
            model: 'claude-haiku-4-5',
            invocations: 3,
            elapsed_seconds: 3,
            input_tokens: 20,
            output_tokens: 20,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 20,
            tool_calls_total: 2,
          },
          {
            runtime: 'claude',
            model: 'claude-opus-5',
            invocations: 1,
            elapsed_seconds: 7,
            input_tokens: 100,
            output_tokens: 60,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 200,
            tool_calls_total: 6,
          },
        ],
      }),
    ]);

    const row = breakdown.run_rows[0];
    expect(row.model_count).toBe(2);
    expect(row.models.map((model) => model.model_exact)).toEqual([
      'claude-opus-5',
      'claude-haiku-4-5',
    ]);
    expect(row.model_exact).toBe('claude-opus-5');
    expect(row.models[0].total_tokens).toBe(360);
    expect(row.models[1].invocations).toBe(3);
    expect(row.models[1].tool_calls_total).toBe(2);
  });

  it('merges repeated entries for the same runtime and model', () => {
    const breakdown = buildMetricsBreakdown([
      runItem({
        model_breakdown: [
          {
            runtime: 'claude',
            model: 'claude-opus-5',
            invocations: 1,
            input_tokens: 10,
            output_tokens: 5,
            tool_calls_total: 1,
            elapsed_seconds: 2,
          },
          {
            runtime: 'claude',
            model: 'claude-opus-5',
            invocations: 2,
            input_tokens: 30,
            output_tokens: 15,
            tool_calls_total: 4,
            elapsed_seconds: 3,
          },
        ],
      }),
    ]);

    const row = breakdown.run_rows[0];
    expect(row.model_count).toBe(1);
    expect(row.models).toHaveLength(1);
    expect(row.models[0].invocations).toBe(3);
    expect(row.models[0].total_tokens).toBe(60);
    expect(row.models[0].elapsed_seconds).toBe(5);
  });

  it('falls back to the summary model when no breakdown is recorded', () => {
    const breakdown = buildMetricsBreakdown([runItem({ model_breakdown: undefined })]);

    const row = breakdown.run_rows[0];
    expect(row.model_count).toBe(1);
    expect(row.model_exact).toBe('claude-opus-5');
    expect(row.models[0].total_tokens).toBe(420);
    expect(row.models[0].runtime).toBe('claude');
  });

  it('marks an unspecified model rather than dropping the run', () => {
    const breakdown = buildMetricsBreakdown([
      runItem({ model: undefined, model_breakdown: undefined }),
    ]);

    const row = breakdown.run_rows[0];
    expect(row.model_count).toBe(1);
    expect(row.model_exact).toBe('(unspecified)');
    expect(row.model_label).toBe('Unspecified model');
  });
});
