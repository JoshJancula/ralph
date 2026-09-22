import { defineConfig } from '@playwright/test';

const PORT = Number(process.env['PLAYWRIGHT_PORT'] ?? 4200);

export default defineConfig({
  testDir: './tests',
  testMatch: /.*\.pw\.test\.ts/,
  timeout: 30_000,
  fullyParallel: false,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: process.env['RALPH_DASHBOARD_BASE_URL'] || `http://127.0.0.1:${PORT}`,
    trace: 'retain-on-failure',
  },
});
