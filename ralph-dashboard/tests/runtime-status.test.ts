import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  RUNTIME_STATUS_ORDER,
  enrichClaudeFromAuthOutput,
  enrichCodexFromLoginOutput,
  enrichCursorFromAboutOutput,
  readCodexPlanType,
  readOpenCodeProviders,
} from '../src/server/runtime-status';

describe('runtime status enrichment', () => {
  it('keeps the Runtimes page display order', () => {
    expect([...RUNTIME_STATUS_ORDER]).toEqual([
      'claude',
      'codex',
      'antigravity',
      'cursor',
      'opencode',
    ]);
  });

  it('parses Claude subscription and usage link from auth status JSON', () => {
    const enriched = enrichClaudeFromAuthOutput(
      JSON.stringify({
        loggedIn: true,
        authMethod: 'claude.ai',
        email: 'dev@example.com',
        subscriptionType: 'pro',
      }),
    );
    expect(enriched.accountHint).toBe('dev@example.com');
    expect(enriched.planHint).toBe('Pro');
    expect(enriched.links).toEqual([
      { label: 'Check Claude usage', url: 'https://claude.ai/settings/usage' },
    ]);
  });

  it('parses Codex ChatGPT login hint', () => {
    const enriched = enrichCodexFromLoginOutput('Logged in using ChatGPT\n');
    expect(enriched.planHint).toBe('ChatGPT');
    expect(enriched.links[0]?.url).toBe('https://chatgpt.com/#settings');
  });

  it('parses Cursor subscription tier and model from about output', () => {
    const enriched = enrichCursorFromAboutOutput(`About Cursor CLI

CLI Version         2026.09.15-d2fe57e
Latest              2026.09.15-d2fe57e (up to date)
Model               Auto
Subscription Tier   Pro+
OS                  darwin (arm64)
Terminal            vscode
Shell               bash
User Email          user@example.com
`);
    expect(enriched.accountHint).toBe('user@example.com');
    expect(enriched.planHint).toBe('Pro+');
  });

  it('reads Codex plan_type from newest session rate_limits', async () => {
    const home = await mkdtemp(join(tmpdir(), 'ralph-runtime-codex-'));
    const staleDir = join(home, '.codex', 'sessions', '2026', '01', '01');
    const freshDir = join(home, '.codex', 'sessions', '2026', '09', '18');
    await mkdir(staleDir, { recursive: true });
    await mkdir(freshDir, { recursive: true });
    await writeFile(
      join(staleDir, 'rollout.jsonl'),
      `${JSON.stringify({
        timestamp: '2026-01-01T00:00:00.000Z',
        type: 'event_msg',
        payload: { type: 'token_count', rate_limits: { plan_type: 'free', primary: { used_percent: 1, window_minutes: 10080 } } },
      })}\n`,
    );
    await writeFile(
      join(freshDir, 'rollout.jsonl'),
      `${JSON.stringify({
        timestamp: '2026-09-18T12:00:00.000Z',
        type: 'event_msg',
        payload: { type: 'token_count', rate_limits: { plan_type: 'plus', primary: { used_percent: 83, window_minutes: 10080 } } },
      })}\n`,
    );
    expect(await readCodexPlanType(home)).toBe('Plus');
  });

  it('detects OpenCode ollama-cloud and other known providers without reading secrets', async () => {
    const home = await mkdtemp(join(tmpdir(), 'ralph-runtime-opencode-'));
    const authDir = join(home, '.local', 'share', 'opencode');
    const configDir = join(home, '.config', 'opencode');
    await mkdir(authDir, { recursive: true });
    await mkdir(configDir, { recursive: true });
    await writeFile(
      join(authDir, 'auth.json'),
      JSON.stringify({
        'ollama-cloud': { type: 'api', key: 'SECRET_SHOULD_NOT_LEAK' },
        openrouter: { type: 'api', key: 'ANOTHER_SECRET' },
      }),
    );
    await writeFile(
      join(configDir, 'opencode.json'),
      JSON.stringify({
        provider: {
          vercel: { options: {} },
        },
      }),
    );

    const { providers, links } = await readOpenCodeProviders(home);
    expect(providers).toEqual(['Ollama Cloud', 'OpenRouter', 'Vercel AI Gateway']);
    expect(links).toEqual(
      expect.arrayContaining([
        { label: 'View Ollama Usage', url: 'https://ollama.com/settings' },
        { label: 'OpenRouter credits', url: 'https://openrouter.ai/settings/credits' },
        { label: 'Vercel AI Gateway', url: 'https://vercel.com/dashboard' },
      ]),
    );
    expect(JSON.stringify({ providers, links })).not.toContain('SECRET');
  });
});
