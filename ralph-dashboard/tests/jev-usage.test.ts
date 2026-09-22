import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { collectJevUsage } from '../src/server/jev-usage';

function line(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    timestamp: '2026-09-21T10:00:00Z',
    model: 'jev-1.13.0',
    questionSetId: 'graph.router-confidence',
    input_tokens: 296,
    output_tokens: 20,
    usageSource: 'measured',
    transport: 'https',
    planKey: 'p',
    ...overrides,
  });
}

async function makeWorkspace(lines: string[]): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), 'ralph-jev-usage-'));
  await mkdir(join(root, 'logs'), { recursive: true });
  await mkdir(join(root, 'jev'), { recursive: true });
  await writeFile(join(root, 'jev', 'usage.jsonl'), lines.join('\n') + '\n', 'utf8');
  return join(root, 'logs');
}

describe('collectJevUsage', () => {
  it('sums calls and tokens per question set and reports enabled', async () => {
    const logs = await makeWorkspace([
      line(),
      line({ input_tokens: 100, output_tokens: 5 }),
      line({ questionSetId: 'compaction.line-relevance' }),
    ]);
    const out = await collectJevUsage({ logsRoots: [logs] });
    expect(out.enabled).toBe(true);
    expect(out.calls).toBe(3);
    expect(out.input_tokens).toBe(692);
    expect(out.output_tokens).toBe(45);
    expect(out.by_question_set[0]).toEqual({
      question_set_id: 'graph.router-confidence',
      calls: 2,
      input_tokens: 396,
      output_tokens: 25,
    });
  });

  it('ignores fixture traffic, bad lines, and counts missing usage as unavailable', async () => {
    const logs = await makeWorkspace([
      line({ transport: 'fixture' }),
      'not json',
      '[1]',
      line({ usageSource: 'unavailable', input_tokens: 0, output_tokens: 0 }),
    ]);
    const out = await collectJevUsage({ logsRoots: [logs] });
    expect(out.calls).toBe(1);
    expect(out.calls_unavailable).toBe(1);
    expect(out.calls_measured).toBe(0);
  });

  it('applies the date scope, treating a bare date upper bound as the whole day', async () => {
    const logs = await makeWorkspace([
      line({ timestamp: '2026-09-20T23:59:59Z' }),
      line({ timestamp: '2026-09-21T23:00:00Z' }),
      line({ timestamp: '2026-09-22T00:00:01Z' }),
    ]);
    const out = await collectJevUsage({ logsRoots: [logs], dateFrom: '2026-09-21', dateTo: '2026-09-21' });
    expect(out.calls).toBe(1);
  });

  it('is disabled with no usage file and prices input only by default', async () => {
    const empty = await mkdtemp(join(tmpdir(), 'ralph-jev-usage-empty-'));
    const none = await collectJevUsage({ logsRoots: [join(empty, 'logs')] });
    expect(none.enabled).toBe(false);
    expect(none.estimated_usd).toBe(0);

    const logs = await makeWorkspace([line({ input_tokens: 1_000_000, output_tokens: 1_000_000 })]);
    const priced = await collectJevUsage({ logsRoots: [logs] });
    expect(priced.estimated_usd).toBeCloseTo(0.042, 6);
  });
});
