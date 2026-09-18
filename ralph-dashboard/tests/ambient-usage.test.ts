import { cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  collectAntigravityAmbientUsage,
  rateLimitsFromAgyUsagePayload,
} from '../src/server/ambient-usage/antigravity';
import { clearAmbientUsageCache, collectAmbientUsage } from '../src/server/ambient-usage';

const fixturesDir = join(process.cwd(), 'tests/fixtures/ambient-usage');

/** Keep tests offline from a real agy binary on the developer PATH. */
const noAgy = { binary: null as string | null };

async function makeHomeFixture(): Promise<string> {
  const home = await mkdtemp(join(tmpdir(), 'ralph-ambient-home-'));
  const claudeDir = join(home, '.claude');
  const projectsDir = join(claudeDir, 'projects', 'demo');
  await mkdir(projectsDir, { recursive: true });
  await cp(join(fixturesDir, 'claude-sample.jsonl'), join(projectsDir, 'session.jsonl'));
  await cp(join(fixturesDir, 'claude-quota.json'), join(home, '.claude.json'));

  const codexDir = join(home, '.codex', 'sessions', '2026', '09', '10');
  await mkdir(codexDir, { recursive: true });
  await cp(join(fixturesDir, 'codex-sample.jsonl'), join(codexDir, 'rollout.jsonl'));
  return home;
}

describe('ambient usage collectors', () => {
  const prevAmbient = process.env['RALPH_DASHBOARD_AMBIENT_USAGE'];

  beforeEach(() => {
    clearAmbientUsageCache();
    process.env['RALPH_DASHBOARD_AMBIENT_USAGE'] = '1';
    process.env['RALPH_DASHBOARD_AMBIENT_USAGE_TTL_MS'] = '0';
  });

  afterEach(() => {
    clearAmbientUsageCache();
    if (prevAmbient === undefined) {
      delete process.env['RALPH_DASHBOARD_AMBIENT_USAGE'];
    } else {
      process.env['RALPH_DASHBOARD_AMBIENT_USAGE'] = prevAmbient;
    }
    delete process.env['RALPH_DASHBOARD_AMBIENT_USAGE_TTL_MS'];
  });

  it('returns disabled payload when opt-out env is set', async () => {
    process.env['RALPH_DASHBOARD_AMBIENT_USAGE'] = '0';
    const response = await collectAmbientUsage({});
    expect(response.enabled).toBe(false);
    expect(response.providers).toEqual([]);
  });

  it('aggregates Claude transcripts and quota without leaking oauth fields', async () => {
    const home = await makeHomeFixture();
    const response = await collectAmbientUsage(
      { dateFrom: '2026-09-10', dateTo: '2026-09-10' },
      { homeDir: home, bypassCache: true, antigravity: noAgy },
    );
    expect(response.enabled).toBe(true);
    const claude = response.providers.find((p) => p.id === 'claude_code');
    expect(claude?.status).toBe('available');
    expect(claude?.tokens.input_tokens).toBe(100);
    expect(claude?.tokens.output_tokens).toBe(50);
    expect(claude?.rate_limits.some((w) => w.id === 'five_hour' && w.used_percent === 12.5)).toBe(true);
    expect(JSON.stringify(response)).not.toContain('oauthToken');
  });

  it('aggregates Codex session totals and rate limits', async () => {
    const home = await makeHomeFixture();
    const response = await collectAmbientUsage(
      { dateFrom: '2026-09-10', dateTo: '2026-09-10' },
      { homeDir: home, bypassCache: true, antigravity: noAgy },
    );
    const codex = response.providers.find((p) => p.id === 'codex');
    expect(codex?.status).toBe('available');
    expect(codex?.tokens.input_tokens).toBe(1500);
    expect(codex?.tokens.output_tokens).toBe(250);
    expect(codex?.tokens.cache_read_input_tokens).toBe(120);
    expect(codex?.rate_limits.some((w) => w.id === 'weekly' && w.used_percent === 20)).toBe(true);
    expect(codex?.rate_limits.some((w) => w.id === 'five_hour' && w.used_percent === 20)).toBe(true);
  });

  it('reads weekly quota from Codex primary when secondary is null', async () => {
    const home = await mkdtemp(join(tmpdir(), 'ralph-ambient-codex-primary-'));
    const codexDir = join(home, '.codex', 'sessions', '2026', '09', '18');
    await mkdir(codexDir, { recursive: true });
    await cp(join(fixturesDir, 'codex-primary-weekly.jsonl'), join(codexDir, 'rollout.jsonl'));

    const response = await collectAmbientUsage({}, { homeDir: home, bypassCache: true, antigravity: noAgy });
    const codex = response.providers.find((p) => p.id === 'codex');
    expect(codex?.rate_limits).toEqual([
      expect.objectContaining({ id: 'weekly', label: 'Weekly', used_percent: 83 }),
    ]);
  });

  it('prefers the newest Codex quota snapshot over older session files', async () => {
    const home = await mkdtemp(join(tmpdir(), 'ralph-ambient-codex-newest-'));
    const staleDir = join(home, '.codex', 'sessions', '2026', '01', '01');
    const freshDir = join(home, '.codex', 'sessions', '2026', '09', '18');
    await mkdir(staleDir, { recursive: true });
    await mkdir(freshDir, { recursive: true });
    await cp(join(fixturesDir, 'codex-stale-weekly.jsonl'), join(staleDir, 'rollout.jsonl'));
    await cp(join(fixturesDir, 'codex-primary-weekly.jsonl'), join(freshDir, 'rollout.jsonl'));

    const response = await collectAmbientUsage({}, { homeDir: home, bypassCache: true, antigravity: noAgy });
    const codex = response.providers.find((p) => p.id === 'codex');
    expect(codex?.rate_limits.some((w) => w.id === 'weekly' && w.used_percent === 83)).toBe(true);
  });

  it('keeps live Codex quota even when transcript date filter excludes the snapshot day', async () => {
    const home = await mkdtemp(join(tmpdir(), 'ralph-ambient-codex-quota-scope-'));
    const codexDir = join(home, '.codex', 'sessions', '2026', '09', '18');
    await mkdir(codexDir, { recursive: true });
    await cp(join(fixturesDir, 'codex-primary-weekly.jsonl'), join(codexDir, 'rollout.jsonl'));

    const response = await collectAmbientUsage(
      { dateFrom: '2026-09-01', dateTo: '2026-09-02' },
      { homeDir: home, bypassCache: true, antigravity: noAgy },
    );
    const codex = response.providers.find((p) => p.id === 'codex');
    expect(codex?.tokens.total_tokens).toBe(0);
    expect(codex?.rate_limits.some((w) => w.id === 'weekly' && w.used_percent === 83)).toBe(true);
  });

  it('filters Claude lines outside date scope', async () => {
    const home = await makeHomeFixture();
    const response = await collectAmbientUsage(
      { dateFrom: '2026-09-11', dateTo: '2026-09-11' },
      { homeDir: home, bypassCache: true, antigravity: noAgy },
    );
    const claude = response.providers.find((p) => p.id === 'claude_code');
    expect(claude?.tokens.input_tokens).toBe(20);
    expect(claude?.tokens.output_tokens).toBe(30);
  });

  it('reports not_installed when directories are missing', async () => {
    const home = await mkdtemp(join(tmpdir(), 'ralph-ambient-empty-'));
    await writeFile(join(home, '.keep'), '');
    const response = await collectAmbientUsage({}, { homeDir: home, bypassCache: true, antigravity: noAgy });
    expect(response.providers.every((p) => p.status === 'not_installed')).toBe(true);
  });

  it('maps Antigravity remaining_fraction buckets into used_percent windows', async () => {
    const raw = JSON.parse(await readFile(join(fixturesDir, 'agy-usage.json'), 'utf8')) as unknown;
    const windows = rateLimitsFromAgyUsagePayload(raw);
    expect(windows).toEqual([
      expect.objectContaining({
        id: '3p-weekly',
        label: 'Claude and GPT models · Weekly Limit',
        used_percent: 58,
      }),
      expect.objectContaining({
        id: 'gemini-weekly',
        label: 'Gemini Models · Weekly Limit',
        used_percent: 83,
      }),
    ]);
  });

  it('collects Antigravity quota via agy usage JSON', async () => {
    const fixture = await readFile(join(fixturesDir, 'agy-usage.json'), 'utf8');
    const home = await makeHomeFixture();
    const response = await collectAmbientUsage(
      {},
      {
        homeDir: home,
        bypassCache: true,
        antigravity: {
          binary: 'agy',
          runner: async () => ({ stdout: fixture, stderr: '' }),
        },
      },
    );
    const agy = response.providers.find((p) => p.id === 'antigravity');
    expect(agy?.status).toBe('available');
    expect(agy?.rate_limits.some((w) => w.id === 'gemini-weekly' && w.used_percent === 83)).toBe(true);
    expect(agy?.rate_limits.some((w) => w.id === '3p-weekly' && w.used_percent === 58)).toBe(true);
  });

  it('reports Antigravity not_installed when binary is missing', async () => {
    const report = await collectAntigravityAmbientUsage(
      { from: null, to: null, label: 'All available history' },
      {},
      { binary: null },
    );
    expect(report.status).toBe('not_installed');
    expect(report.rate_limits).toEqual([]);
  });
});
