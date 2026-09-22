import { test, expect } from '@playwright/test';
import { join } from 'node:path';

const FIXTURE_ROOT = join(__dirname, 'fixtures', 'acceptance-workspace');
const PROJECT_ROOT = encodeURIComponent(FIXTURE_ROOT);
const PLAN_PATH = encodeURIComponent('.ralph-workspace/plans/nav-v2-failed.md');
const RUN_ID = 'run-nav-v2-failed';

/**
 * Layout-2 catalog navigation: from the plan run list, reach a failed check's
 * exact command and output, then the related artifact, in at most three clicks.
 */
test.describe('state navigation (layout 2)', () => {
  test('failed check command, output, and artifact within three clicks', async ({ page }) => {
    let clicks = 0;
    page.on('click', () => {
      clicks += 1;
    });

    await page.goto(`/plan-detail/${PLAN_PATH}/logs?projectRoot=${PROJECT_ROOT}`);
    await page.waitForSelector('[data-testid="plan-runs-list"]');

    // Child attempts nest under the outer card — no duplicate top-level card.
    await expect(page.locator('[data-testid="plan-run-card"]')).toHaveCount(1);
    await expect(page.locator('[data-testid="plan-run-child-card"]')).toHaveCount(1);
    await expect(page.locator('[data-testid="plan-run-children"]')).toBeVisible();

    // Click 1: open the failed outer run from the list.
    await page.locator('[data-testid="plan-run-card"]').filter({ hasText: RUN_ID }).click();
    await page.waitForSelector('[data-testid="plan-run-detail"]');

    await expect(page.locator('[data-testid="run-nav-task"]')).toContainText('Prove dashboard navigation');
    await expect(page.locator('[data-testid="run-nav-status"]')).toContainText('failed');
    await expect(page.locator('[data-testid="run-details-disclosure"]')).toBeVisible();
    await expect(page.locator('[data-testid="run-raw-files"]')).toHaveCount(0);

    // Click 2: open the failed check.
    await page.locator('[data-testid="run-failed-check"]').click();
    await expect(page.locator('[data-testid="run-failed-check-detail"]')).toBeVisible();
    await expect(page.locator('[data-testid="run-failed-check-command"]')).toContainText(
      'npm test -- --runInBand failing-nav-check',
    );
    await expect(page.locator('[data-testid="run-failed-check-output"]')).toContainText('FAIL failing-nav-check');

    // Click 3: open the related artifact.
    await page.locator('[data-testid="run-failed-check-artifact"]').click();
    await page.waitForSelector('app-file-viewer, ralph-log-viewer, [data-testid="file-viewer"], .file-viewer', {
      timeout: 15_000,
    });
    await expect(page.getByText(/Related check artifact|linked from the failed check/i).first()).toBeVisible();

    expect(clicks).toBeLessThanOrEqual(3);
  });
});
