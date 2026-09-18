import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const DASHBOARD_ROOT = resolve(TEST_DIR, '..');
const REPO_ROOT = resolve(DASHBOARD_ROOT, '..');
const WRAPPER = join(DASHBOARD_ROOT, 'scripts', 'build-in-container.sh');
const BUNDLE_RALPH = join(REPO_ROOT, 'bundle', '.ralph');

/** PATH with common system bins but no Docker install locations. */
const PATH_WITHOUT_DOCKER = ['/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':');

function runWrapper(
  scriptPath: string,
  env: NodeJS.ProcessEnv,
): { status: number | null; stdout: string; stderr: string } {
  const result = spawnSync('bash', [scriptPath], {
    env: { ...process.env, ...env },
    encoding: 'utf8',
  });
  return {
    status: result.status,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
  };
}

function writeFakeDocker(binDir: string, distSeedDir: string): string {
  mkdirSync(binDir, { recursive: true });
  const dockerPath = join(binDir, 'docker');
  writeFileSync(
    dockerPath,
    `#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
shift || true
case "$cmd" in
  build)
    exit 0
    ;;
  create)
    echo "test-container-id"
    exit 0
    ;;
  cp)
    # docker cp <id>:/app/dist/. <host-dist>/
    dest="\${2:-}"
    if [[ -z "$dest" ]]; then
      echo "fake docker cp: missing dest" >&2
      exit 1
    fi
    mkdir -p "$dest"
    cp -R "${distSeedDir}/." "$dest/"
    exit 0
    ;;
  rm)
    exit 0
    ;;
  *)
    echo "fake docker: unexpected command: $cmd $*" >&2
    exit 1
    ;;
esac
`,
    { mode: 0o755 },
  );
  chmodSync(dockerPath, 0o755);
  return dockerPath;
}

function collectFiles(root: string, predicate: (name: string) => boolean): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === 'node_modules' || entry.name === '.git') continue;
        walk(full);
      } else if (entry.isFile() && predicate(entry.name)) {
        out.push(full);
      }
    }
  };
  walk(root);
  return out;
}

describe('build-in-container.sh', () => {
  it('exits cleanly with an actionable message when Docker is absent', () => {
    expect(existsSync(WRAPPER)).toBe(true);

    const { status, stdout, stderr } = runWrapper(WRAPPER, {
      PATH: PATH_WITHOUT_DOCKER,
    });

    expect(status).toBe(1);
    expect(stdout).toBe('');
    expect(stderr).toMatch(/Docker was not found on PATH/i);
    expect(stderr).toMatch(/npm run build/);
    expect(stderr).toMatch(/build-in-container\.sh/);
  });

  it('builds and extracts dist/ when a Docker CLI is present', () => {
    const fixtureRoot = mkdtempSync(join(tmpdir(), 'ralph-dashboard-build-'));
    const seedDist = join(fixtureRoot, 'seed-dist');
    const scriptsDir = join(fixtureRoot, 'scripts');
    try {
      mkdirSync(scriptsDir, { recursive: true });
      mkdirSync(join(seedDist, 'ralph-dashboard'), { recursive: true });
      writeFileSync(join(seedDist, 'ralph-dashboard', 'index.html'), '<html>ok</html>\n');
      writeFileSync(join(fixtureRoot, 'Dockerfile.build'), '# test fixture\nFROM scratch\n');
      cpSync(WRAPPER, join(scriptsDir, 'build-in-container.sh'));

      const binDir = join(fixtureRoot, 'bin');
      writeFakeDocker(binDir, seedDist);

      const { status, stdout, stderr } = runWrapper(join(scriptsDir, 'build-in-container.sh'), {
        PATH: `${binDir}:${PATH_WITHOUT_DOCKER}`,
        RALPH_DASHBOARD_BUILD_IMAGE: 'ralph-dashboard-build-test',
      });

      expect(stderr).toBe('');
      expect(status).toBe(0);
      expect(stdout).toMatch(/Extracted container/);
      expect(stdout).toMatch(/OK: .*\/dist\/ralph-dashboard/);
      expect(existsSync(join(fixtureRoot, 'dist', 'ralph-dashboard', 'index.html'))).toBe(true);
      expect(readFileSync(join(fixtureRoot, 'dist', 'ralph-dashboard', 'index.html'), 'utf8')).toContain(
        'ok',
      );
    } finally {
      rmSync(fixtureRoot, { recursive: true, force: true });
    }
  });

  it('guards Docker discovery with command -v docker in the wrapper', () => {
    const source = readFileSync(WRAPPER, 'utf8');
    expect(source).toMatch(/command -v docker\s*>\/dev\/null\s*2>&1/);
  });
});

describe('bundle/.ralph Docker optionality', () => {
  it('does not invoke the Docker CLI as an unguarded runtime requirement', () => {
    expect(statSync(BUNDLE_RALPH).isDirectory()).toBe(true);

    // CLI invocations look like a shell word `docker` followed by a subcommand.
    // Blocklists, output classifiers, and docs that only mention the token are allowed.
    const invokeRe =
      /(?:^|[^"'=#|\w.-])docker\s+(?:build|run|create|cp|pull|push|exec|compose|images|ps|logs|rmi|rm|tag|login|logout|volume|network|context|info|version)\b/;

    const offenders: string[] = [];
    for (const file of collectFiles(BUNDLE_RALPH, (name) => name.endsWith('.sh') || name.endsWith('.py'))) {
      const text = readFileSync(file, 'utf8');
      const lines = text.split(/\r?\n/);
      for (let i = 0; i < lines.length; i++) {
        const trimmed = lines[i].trim();
        if (!trimmed || trimmed.startsWith('#') || trimmed.startsWith('//')) continue;
        // Strip quotes/backticks so tokens inside string literals, docs, and regexes are ignored.
        const unquoted = lines[i]
          .replace(/'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`/g, '""');
        if (!invokeRe.test(unquoted)) continue;
        const prior = lines.slice(0, i + 1).join('\n');
        if (/command\s+-v\s+docker\b/.test(prior)) continue;
        offenders.push(`${file}:${i + 1}: ${trimmed}`);
      }
    }

    expect(offenders).toEqual([]);
  });
});
