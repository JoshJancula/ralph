import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { readFile, readdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

import { resolveRuntimeBinary, type SupportedRuntime } from './ralph-cli';

const execFileAsync = promisify(execFile);
const PROBE_TIMEOUT_MS = 5000;

/** Display order for the Runtimes page (independent of SUPPORTED_RUNTIMES). */
export const RUNTIME_STATUS_ORDER = [
  'claude',
  'codex',
  'antigravity',
  'cursor',
  'opencode',
] as const satisfies readonly SupportedRuntime[];

export type RuntimeConnectionState = 'connected' | 'not_connected' | 'not_installed';

export interface RuntimeExternalLink {
  readonly label: string;
  readonly url: string;
}

export interface RuntimeConnectionStatus {
  readonly runtimeId: SupportedRuntime;
  readonly label: string;
  readonly state: RuntimeConnectionState;
  readonly detail: string | null;
  readonly accountHint: string | null;
  /** Human-readable subscription / plan label when known. */
  readonly planHint: string | null;
  /** Detected OpenCode (or similar) provider ids with friendly labels. */
  readonly providers: readonly string[];
  /** External billing / usage dashboards when local quota is unavailable. */
  readonly links: readonly RuntimeExternalLink[];
}

const RUNTIME_PROBES: Readonly<
  Record<SupportedRuntime, { label: string; args: readonly string[]; signedOut: RegExp }>
> = {
  cursor: {
    label: 'Cursor Agent',
    args: ['status'],
    signedOut: /not logged in|logged ?out|not authenticated/iu,
  },
  claude: {
    label: 'Claude (Anthropic)',
    args: ['auth', 'status'],
    signedOut: /not logged in|logged ?out|not authenticated/iu,
  },
  codex: {
    label: 'Codex (OpenAI)',
    args: ['login', 'status'],
    signedOut: /not logged in|logged ?out|not authenticated/iu,
  },
  opencode: {
    label: 'OpenCode',
    args: ['auth', 'list'],
    signedOut: /no credentials|not logged in|logged ?out/iu,
  },
  antigravity: {
    label: 'Antigravity (Google)',
    args: ['models'],
    signedOut: /not signed in|sign in|select login method|authentication required/iu,
  },
};

/** Known OpenCode provider ids → billing / settings pages. */
const OPENCODE_PROVIDER_LINKS: Readonly<
  Record<string, { label: string; displayName: string; url: string }>
> = {
  'ollama-cloud': {
    label: 'View Ollama Usage',
    displayName: 'Ollama Cloud',
    url: 'https://ollama.com/settings',
  },
  ollama: {
    label: 'View Ollama Usage',
    displayName: 'Ollama',
    url: 'https://ollama.com/settings',
  },
  openrouter: {
    label: 'OpenRouter credits',
    displayName: 'OpenRouter',
    url: 'https://openrouter.ai/settings/credits',
  },
  anthropic: {
    label: 'Anthropic billing',
    displayName: 'Anthropic',
    url: 'https://console.anthropic.com/settings/billing',
  },
  openai: {
    label: 'OpenAI billing',
    displayName: 'OpenAI',
    url: 'https://platform.openai.com/settings/organization/billing',
  },
  vercel: {
    label: 'Vercel AI Gateway',
    displayName: 'Vercel AI Gateway',
    url: 'https://vercel.com/dashboard',
  },
  'cloudflare-ai-gateway': {
    label: 'Cloudflare AI Gateway',
    displayName: 'Cloudflare AI Gateway',
    url: 'https://dash.cloudflare.com',
  },
  opencode: {
    label: 'OpenCode auth',
    displayName: 'OpenCode Zen',
    url: 'https://opencode.ai/auth',
  },
  'github-copilot': {
    label: 'GitHub Copilot settings',
    displayName: 'GitHub Copilot',
    url: 'https://github.com/settings/copilot',
  },
  groq: {
    label: 'Groq console',
    displayName: 'Groq',
    url: 'https://console.groq.com',
  },
  deepseek: {
    label: 'DeepSeek platform',
    displayName: 'DeepSeek',
    url: 'https://platform.deepseek.com',
  },
  google: {
    label: 'Google AI Studio',
    displayName: 'Google',
    url: 'https://aistudio.google.com',
  },
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function accountHint(output: string): string | null {
  const match = output.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/iu);
  return match?.[0] ?? null;
}

function titleCasePlan(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) {
    return trimmed;
  }
  if (/^[a-z0-9_-]+$/i.test(trimmed)) {
    return trimmed
      .split(/[-_]/u)
      .filter(Boolean)
      .map((part) => part.charAt(0).toUpperCase() + part.slice(1).toLowerCase())
      .join(' ');
  }
  return trimmed;
}

function parseJsonObject(text: string): Record<string, unknown> | null {
  const trimmed = text.trim();
  if (!trimmed) {
    return null;
  }
  try {
    const parsed = JSON.parse(trimmed) as unknown;
    return isRecord(parsed) ? parsed : null;
  } catch {
    const start = trimmed.indexOf('{');
    const end = trimmed.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        const parsed = JSON.parse(trimmed.slice(start, end + 1)) as unknown;
        return isRecord(parsed) ? parsed : null;
      } catch {
        return null;
      }
    }
    return null;
  }
}

function stripAnsi(text: string): string {
  return text.replace(/\u001b\[[0-9;]*m/gu, '');
}

export function enrichClaudeFromAuthOutput(output: string): {
  accountHint: string | null;
  planHint: string | null;
  links: RuntimeExternalLink[];
} {
  const parsed = parseJsonObject(output);
  const email =
    parsed && typeof parsed['email'] === 'string' && parsed['email'].trim()
      ? parsed['email'].trim()
      : accountHint(output);
  const subscription =
    parsed && typeof parsed['subscriptionType'] === 'string' && parsed['subscriptionType'].trim()
      ? titleCasePlan(parsed['subscriptionType'])
      : null;
  const authMethod =
    parsed && typeof parsed['authMethod'] === 'string' ? parsed['authMethod'].trim() : '';
  const links: RuntimeExternalLink[] =
    authMethod === 'claude.ai' || subscription
      ? [{ label: 'Check Claude usage', url: 'https://claude.ai/settings/usage' }]
      : [{ label: 'Anthropic console', url: 'https://console.anthropic.com/settings/billing' }];
  return { accountHint: email, planHint: subscription, links };
}

export function enrichCodexFromLoginOutput(output: string): {
  planHint: string | null;
  links: RuntimeExternalLink[];
} {
  const planHint = /chatgpt/iu.test(output)
    ? 'ChatGPT'
    : /api[_\s-]?key/iu.test(output)
      ? 'API key'
      : null;
  return {
    planHint,
    links: [{ label: 'Check ChatGPT billing', url: 'https://chatgpt.com/#settings' }],
  };
}

function fieldFromAbout(output: string, label: string): string | null {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
  const match = new RegExp(`^${escaped}\\s+(.+?)\\s*$`, 'imu').exec(output);
  const value = match?.[1]?.trim();
  return value || null;
}

export function enrichCursorFromAboutOutput(output: string): {
  accountHint: string | null;
  planHint: string | null;
} {
  const email = fieldFromAbout(output, 'User Email') ?? accountHint(output);
  const tier = fieldFromAbout(output, 'Subscription Tier');
  return {
    accountHint: email,
    planHint: tier,
  };
}

export async function readCodexPlanType(home = homedir()): Promise<string | null> {
  const sessionsDir = join(home, '.codex', 'sessions');
  if (!existsSync(sessionsDir)) {
    return null;
  }
  const files: string[] = [];
  async function walk(dir: string): Promise<void> {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        files.push(full);
      }
    }
  }
  await walk(sessionsDir);
  files.sort((a, b) => (a < b ? 1 : a > b ? -1 : 0));
  for (const file of files.slice(0, 8)) {
    let text = '';
    try {
      text = await readFile(file, 'utf8');
    } catch {
      continue;
    }
    const lines = text.trimEnd().split('\n');
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      const line = lines[i];
      if (!line.includes('plan_type') || !line.includes('rate_limits')) {
        continue;
      }
      try {
        const record = JSON.parse(line) as Record<string, unknown>;
        const payload = record['payload'];
        if (!isRecord(payload)) {
          continue;
        }
        const rateLimits = payload['rate_limits'];
        if (isRecord(rateLimits) && typeof rateLimits['plan_type'] === 'string') {
          const plan = rateLimits['plan_type'].trim();
          if (plan) {
            return titleCasePlan(plan);
          }
        }
      } catch {
        // skip malformed lines
      }
    }
  }
  return null;
}

export async function readOpenCodeProviders(home = homedir()): Promise<{
  providers: string[];
  links: RuntimeExternalLink[];
}> {
  const authPath = join(home, '.local', 'share', 'opencode', 'auth.json');
  const ids = new Set<string>();
  if (existsSync(authPath)) {
    try {
      const raw = await readFile(authPath, 'utf8');
      const parsed = JSON.parse(raw) as unknown;
      if (isRecord(parsed)) {
        for (const key of Object.keys(parsed)) {
          if (key.trim()) {
            ids.add(key.trim());
          }
        }
      }
    } catch {
      // ignore unreadable auth
    }
  }

  const configCandidates = [
    join(home, '.config', 'opencode', 'opencode.json'),
    join(home, '.opencode', 'opencode.json'),
  ];
  for (const configPath of configCandidates) {
    if (!existsSync(configPath)) {
      continue;
    }
    try {
      const raw = await readFile(configPath, 'utf8');
      // OpenCode configs may be JSONC; strip simple // and /* */ comments for key detection.
      const stripped = raw
        .replace(/\/\*[\s\S]*?\*\//gu, '')
        .replace(/^\s*\/\/.*$/gmu, '');
      const parsed = JSON.parse(stripped) as unknown;
      if (isRecord(parsed) && isRecord(parsed['provider'])) {
        for (const key of Object.keys(parsed['provider'])) {
          if (key.trim()) {
            ids.add(key.trim());
          }
        }
      }
    } catch {
      // ignore unreadable config
    }
  }

  const providers: string[] = [];
  const links: RuntimeExternalLink[] = [];
  const seenUrls = new Set<string>();
  for (const id of [...ids].sort()) {
    const known = OPENCODE_PROVIDER_LINKS[id];
    providers.push(known?.displayName ?? titleCasePlan(id));
    if (known && !seenUrls.has(known.url)) {
      seenUrls.add(known.url);
      links.push({ label: known.label, url: known.url });
    }
  }
  return { providers, links };
}

function baseStatus(
  runtimeId: SupportedRuntime,
  state: RuntimeConnectionState,
  detail: string | null,
  accountHintValue: string | null = null,
): RuntimeConnectionStatus {
  return {
    runtimeId,
    label: RUNTIME_PROBES[runtimeId].label,
    state,
    detail,
    accountHint: accountHintValue,
    planHint: null,
    providers: [],
    links: [],
  };
}

async function enrichConnected(
  runtimeId: SupportedRuntime,
  output: string,
  home: string,
  binary: string | null,
): Promise<Pick<RuntimeConnectionStatus, 'accountHint' | 'planHint' | 'providers' | 'links' | 'detail'>> {
  switch (runtimeId) {
    case 'claude': {
      const enriched = enrichClaudeFromAuthOutput(output);
      return {
        accountHint: enriched.accountHint,
        planHint: enriched.planHint,
        providers: [],
        links: enriched.links,
        detail: null,
      };
    }
    case 'codex': {
      const enriched = enrichCodexFromLoginOutput(output);
      const planType = await readCodexPlanType(home);
      const planHint = planType
        ? enriched.planHint
          ? `${enriched.planHint} · ${planType}`
          : planType
        : enriched.planHint;
      return {
        accountHint: accountHint(output),
        planHint,
        providers: [],
        links: enriched.links,
        detail: null,
      };
    }
    case 'cursor': {
      let aboutAccount = accountHint(output);
      let planHint: string | null = null;
      if (binary) {
        try {
          const about = await execFileAsync(binary, ['about'], {
            timeout: PROBE_TIMEOUT_MS,
            maxBuffer: 128 * 1024,
            windowsHide: true,
            env: process.env,
          });
          const aboutOut = `${about.stdout ?? ''}\n${about.stderr ?? ''}`.trim();
          const enriched = enrichCursorFromAboutOutput(aboutOut);
          aboutAccount = enriched.accountHint ?? aboutAccount;
          planHint = enriched.planHint;
        } catch {
          // status already confirmed sign-in; about is best-effort plan detail
        }
      }
      return {
        accountHint: aboutAccount,
        planHint,
        providers: [],
        links: [{ label: 'View Cursor Usage', url: 'https://cursor.com/dashboard/billing' }],
        detail: null,
      };
    }
    case 'opencode': {
      const { providers, links } = await readOpenCodeProviders(home);
      const fromCli = stripAnsi(output);
      // Prefer auth.json/config ids; fall back to credential labels from CLI text.
      const providersOut =
        providers.length > 0
          ? providers
          : [...fromCli.matchAll(/●\s+([^\n]+)/gu)].map((m) => m[1].replace(/\s+api\s*$/iu, '').trim()).filter(Boolean);
      return {
        accountHint: accountHint(output),
        planHint: null,
        providers: providersOut,
        links,
        detail: null,
      };
    }
    case 'antigravity': {
      return {
        accountHint: accountHint(output),
        planHint: null,
        providers: [],
        links: [],
        detail: null,
      };
    }
    default:
      return {
        accountHint: accountHint(output),
        planHint: null,
        providers: [],
        links: [],
        detail: null,
      };
  }
}

async function probeRuntime(
  runtimeId: SupportedRuntime,
  home: string,
): Promise<RuntimeConnectionStatus> {
  const probe = RUNTIME_PROBES[runtimeId];
  const binary = resolveRuntimeBinary(runtimeId);
  if (!binary) {
    return baseStatus(runtimeId, 'not_installed', 'CLI not found on PATH');
  }

  try {
    const result = await execFileAsync(binary, [...probe.args], {
      timeout: PROBE_TIMEOUT_MS,
      maxBuffer: 256 * 1024,
      windowsHide: true,
      env: process.env,
    });
    const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`.trim();
    if (probe.signedOut.test(output)) {
      return baseStatus(runtimeId, 'not_connected', 'No active sign-in found');
    }
    const enriched = await enrichConnected(runtimeId, output, home, binary);
    return {
      ...baseStatus(runtimeId, 'connected', enriched.detail, enriched.accountHint),
      planHint: enriched.planHint,
      providers: enriched.providers,
      links: enriched.links,
    };
  } catch (error: unknown) {
    const failure = error as { stdout?: string; stderr?: string; code?: string | number };
    const output = `${failure.stdout ?? ''}\n${failure.stderr ?? ''}`.trim();
    if (probe.signedOut.test(output)) {
      return baseStatus(runtimeId, 'not_connected', 'No active sign-in found');
    }
    return baseStatus(
      runtimeId,
      'not_connected',
      failure.code === 'ETIMEDOUT' ? 'Status check timed out' : 'Failed to verify sign-in',
    );
  }
}

export async function listRuntimeStatuses(options?: {
  homeDir?: string;
}): Promise<readonly RuntimeConnectionStatus[]> {
  const home = options?.homeDir ?? homedir();
  const statuses = await Promise.all(RUNTIME_STATUS_ORDER.map((runtime) => probeRuntime(runtime, home)));
  return statuses;
}
