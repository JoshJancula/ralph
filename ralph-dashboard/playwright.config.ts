import { defineConfig } from '@playwright/test';
import { join } from 'node:path';

const PORT = Number(process.env['PLAYWRIGHT_PORT'] ?? 4200);
const FIXTURE_ROOT = join(__dirname, 'e2e', 'fixtures', 'acceptance-workspace');
const RALPH_STUB = join(__dirname, 'e2e', 'fixtures', 'ralph-stub.sh');

// Every e2e spec runs against the real, built dashboard server (dist/), pointed
// at a real fixture project root (e2e/fixtures/acceptance-workspace) with a
// deterministic `ralph` CLI stub for workflow-run state. Individual specs may
// still use page.route to mock specific responses (see
// workflow-run-detail.spec.ts), but the default is real server + real files,
// per PLAN18's run-end-to-end-acceptance requirement to exercise real code
// paths rather than a developer's personal historical logs.
export default defineConfig({
  testDir: './e2e',
  timeout: 30_000,
  fullyParallel: false,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    trace: 'retain-on-failure',
  },
  webServer: {
    command: 'node scripts/start-server.cjs',
    url: `http://127.0.0.1:${PORT}`,
    reuseExistingServer: !process.env['CI'],
    timeout: 120_000,
    env: {
      PORT: String(PORT),
      HOST: '127.0.0.1',
      RALPH_DASHBOARD_PROJECT_ROOT: FIXTURE_ROOT,
      RALPH_DASHBOARD_WORKSPACE_ROOT: join(FIXTURE_ROOT, '.ralph-workspace'),
      RALPH_DASHBOARD_RALPH_BIN: RALPH_STUB,
    },
  },
});
