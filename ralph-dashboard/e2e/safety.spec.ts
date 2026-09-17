import { test, expect, type Page } from '@playwright/test';
import { existsSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Non-terminal operator journey for the Safety page: status banner, classify a
 * command (deny + matched rule), add a banned path, save, and confirm the
 * value survives reload. Writes go to the acceptance fixture state-root via
 * the real dashboard server (HOST=127.0.0.1 so writeGuard permits them).
 */

const FIXTURE_KILLSWITCH = join(
  __dirname,
  'fixtures',
  'acceptance-workspace',
  '.ralph-workspace',
  'killswitch.json',
);

const BANNED_PATH = '**/e2e-safety-secret/**';

function trackFailures(page: Page): { consoleErrors: string[]; failedRequests: string[] } {
  const consoleErrors: string[] = [];
  const failedRequests: string[] = [];
  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      consoleErrors.push(msg.text());
    }
  });
  page.on('requestfailed', (req) => {
    failedRequests.push(`${req.method()} ${req.url()}: ${req.failure()?.errorText ?? 'unknown'}`);
  });
  page.on('response', (res) => {
    if (res.status() >= 500) {
      failedRequests.push(`${res.request().method()} ${res.url()}: HTTP ${res.status()}`);
    }
  });
  return { consoleErrors, failedRequests };
}

function removeFixtureKillswitch(): void {
  if (existsSync(FIXTURE_KILLSWITCH)) {
    unlinkSync(FIXTURE_KILLSWITCH);
  }
}

test.describe('Safety page journey', () => {
  test.beforeEach(() => {
    removeFixtureKillswitch();
  });

  test.afterEach(() => {
    removeFixtureKillswitch();
  });

  test('status, deny check, save banned path, survive reload', async ({ page }) => {
    const tracking = trackFailures(page);

    await page.goto('/safety');
    await page.waitForSelector('[data-testid="safety-page"]');
    await page.waitForSelector('[data-testid="safety-status-banner"]');

    await expect(page.locator('[data-testid="safety-status-mode"]')).toContainText(/enforcement on/i);
    await expect(page.locator('[data-testid="safety-status-source"]')).toContainText(/bundle|project/i);
    await expect(page.locator('[data-testid="safety-check-copy"]')).toContainText(/never executed/i);

    await page.getByRole('button', { name: 'sudo ls', exact: true }).click();
    await page.locator('[data-testid="safety-check-submit"]').click();
    await expect(page.locator('[data-testid="safety-check-outcome"]')).toHaveText(/deny/i);
    await expect(page.locator('[data-testid="safety-check-matched-rule"]')).toContainText('no_sudo');

    const bannedInput = page.locator('[data-testid="safety-chip-input-banned-paths"]');
    await bannedInput.fill(BANNED_PATH);
    await page.locator('[data-testid="safety-chip-add-banned-paths"]').click();
    await expect(page.locator('[data-testid="safety-chip-list-banned-paths"]')).toContainText(BANNED_PATH);

    await page.locator('[data-testid="safety-save"]').click();
    await expect(page.locator('[data-testid="safety-invalid-diagnostics"]')).toHaveCount(0);
    await expect(page.locator('[data-testid="safety-conflict"]')).toHaveCount(0);
    await expect
      .poll(() => existsSync(FIXTURE_KILLSWITCH), { timeout: 10_000 })
      .toBe(true);

    await page.reload();
    await page.waitForSelector('[data-testid="safety-page"]');
    await page.waitForSelector('[data-testid="safety-chip-list-banned-paths"]');
    await expect(page.locator('[data-testid="safety-chip-list-banned-paths"]')).toContainText(BANNED_PATH);
    await expect(page.locator('[data-testid="safety-create-project-cta"]')).toHaveCount(0);

    expect(tracking.consoleErrors, tracking.consoleErrors.join('\n')).toEqual([]);
    expect(tracking.failedRequests, tracking.failedRequests.join('\n')).toEqual([]);
  });
});
