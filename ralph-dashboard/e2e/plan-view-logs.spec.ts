import { test, expect } from '@playwright/test';
import { join } from 'node:path';

const FIXTURE_ROOT = join(__dirname, 'fixtures', 'acceptance-workspace');
const PROJECT_ROOT = encodeURIComponent(FIXTURE_ROOT);
const LEGACY_PLAN_PATH = encodeURIComponent('.ralph-workspace/plans/view-logs-e2e.md');
const MANIFEST_PLAN_PATH = encodeURIComponent('.ralph-workspace/plans/view-logs-manifest-e2e.md');
const WORKSPACE_ROOT = encodeURIComponent(join(FIXTURE_ROOT, '.ralph-workspace'));
const MANIFEST_RUN_ID = 'run-e2e-20260101T000000Z-test';

test.describe('Plan view logs journeys', () => {
  test('legacy plan: plan detail to evidence, open log, retain workspace', async ({ page }) => {
    await page.goto(`/plan-detail/${LEGACY_PLAN_PATH}?projectRoot=${PROJECT_ROOT}`);
    await page.waitForSelector('.plan-detail');
    await page.getByRole('button', { name: 'View logs' }).click();
    await page.waitForSelector('[data-testid="plan-run-detail"]');

    await expect(page.locator('[data-testid="run-raw-files"]')).toHaveCount(0);
    await expect(page.locator('[data-testid="run-evidence"]')).toBeVisible();
    await expect(page.locator('[data-testid="run-legacy-badge"]')).toBeVisible();
    await expect(page.locator('[data-testid="run-evidence-group-metadata"]')).toBeVisible();
    await expect(page.locator('[data-testid="run-evidence-group-execution"]')).toBeVisible();

    const evidenceButtons = page.locator('[data-testid="run-evidence-open"]');
    await expect(evidenceButtons.first()).toBeVisible();
    expect(await evidenceButtons.count()).toBeGreaterThanOrEqual(5);

    const outputRow = page.locator('.evidence-row').filter({ hasText: 'plan-runner-e2e-output.log' });
    await outputRow.locator('[data-testid="run-evidence-open"]').click();
    await page.waitForSelector('ralph-log-viewer');
    await expect(page.getByText('E2E FIXTURE OUTPUT LINE')).toBeVisible();

    await page.goBack();
    await page.waitForSelector('[data-testid="plan-runs-page"]');
    expect(page.url()).toContain(encodeURIComponent(FIXTURE_ROOT));
    await expect(page.locator('[data-testid="run-evidence"]')).toBeVisible();
  });

  test('legacy plan: file viewer View Logs opens latest log', async ({ page }) => {
    await page.goto(
      `/plans?projectRoot=${PROJECT_ROOT}&workspaceRoot=${WORKSPACE_ROOT}&path=${encodeURIComponent('.ralph-workspace/plans')}&file=${encodeURIComponent('view-logs-e2e.md')}`,
    );
    await page.waitForSelector('app-file-viewer');
    await page.getByRole('button', { name: 'View Logs' }).click();
    await page.waitForSelector('ralph-log-viewer');
    await expect(page.getByText('E2E FIXTURE OUTPUT LINE')).toBeVisible();
    expect(page.url()).toContain(encodeURIComponent(FIXTURE_ROOT));
  });

  test('manifest run: deep link shows manifest badge and evidence controls', async ({ page }) => {
    await page.goto(
      `/plan-runs/${MANIFEST_RUN_ID}?projectRoot=${PROJECT_ROOT}&plan=${MANIFEST_PLAN_PATH}`,
    );
    await page.waitForSelector('[data-testid="plan-run-detail"]');
    await expect(page.locator('[data-testid="run-manifest-badge"]')).toBeVisible();
    await expect(page.locator('[data-testid="run-raw-files"]')).toHaveCount(0);
    const opens = page.locator('[data-testid="run-evidence-open"]');
    await expect(opens.first()).toBeVisible();
    expect(await opens.count()).toBeGreaterThan(0);
  });

  test('evidence list layout at 390px width', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(`/plan-detail/${LEGACY_PLAN_PATH}/logs?projectRoot=${PROJECT_ROOT}`);
    await page.waitForSelector('[data-testid="run-evidence"]');
    const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
    expect(scrollWidth).toBeLessThanOrEqual(390);
    await expect(page.locator('[data-testid="run-evidence-open"]').first()).toBeVisible();
    await expect(page.locator('.path').first()).toBeVisible();
  });
});
