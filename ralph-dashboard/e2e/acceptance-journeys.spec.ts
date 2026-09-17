import { test, expect, type Page } from '@playwright/test';
import { join } from 'node:path';

const FIXTURE_ROOT = join(__dirname, 'fixtures', 'acceptance-workspace');

/**
 * PLAN18 run-end-to-end-acceptance: the redesign's acceptance journeys,
 * driven against the real dashboard server + a real fixture project root
 * (e2e/fixtures/acceptance-workspace, see playwright.config.ts) rather than
 * a developer's personal historical logs. The fixture includes duplicate
 * plan basenames across two subprojects, a classic plan, a YAML plan, a
 * project-level workflow override (source precedence over the bundled
 * definition), and usage volume. Workflow-run states (waiting approval,
 * failed verification, rework, completed) come from a deterministic `ralph`
 * CLI stub (e2e/fixtures/ralph-stub.sh) that delegates every other
 * subcommand to the real installed `ralph` binary.
 */

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

test.describe('PLAN18 acceptance journeys', () => {
  test('1. find and open a plan, keeping duplicate basenames distinct', async ({ page }) => {
    const tracking = trackFailures(page);
    await page.goto('/plans');
    await page.waitForSelector('[data-testid="plans-inventory"]');

    const rowA = page.locator('.plan-row', { hasText: 'PLAN-widget.plan' }).first();
    const rowB = page.locator('.plan-row', { hasText: 'widget-rollout-team-b' }).first();
    await expect(rowA).toBeVisible();
    await expect(rowB).toBeVisible();

    await rowB.getByRole('button', { name: 'Open plan' }).click();
    await page.waitForSelector('.plan-detail');
    await expect(page.locator('.plan-title')).toContainText('widget-rollout-team-b');
    expect(page.url()).toContain('team-b');

    await page.goBack();
    await page.waitForSelector('[data-testid="plans-inventory"]');
    await rowA.getByRole('button', { name: 'Open plan' }).click();
    await page.waitForSelector('.plan-detail');
    expect(page.url()).toContain('team-a');
    // Team A's plan has no YAML `name:`, so its title falls back to its filename —
    // proving this is genuinely the other plan, not a cached view of team B's.
    await expect(page.locator('.plan-title')).not.toContainText('widget-rollout-team-b');

    expect(tracking.consoleErrors, tracking.consoleErrors.join('\n')).toEqual([]);
    expect(tracking.failedRequests, tracking.failedRequests.join('\n')).toEqual([]);
  });

  test('2. distinguish immutable source from a mutable control copy in Diff mode', async ({ page }) => {
    // No UI path wires a control copy onto a plan automatically today (a known
    // gap — see PLAN18 handoff notes); this exercises the plan-detail
    // component's own diff capability directly via its supported query param,
    // pointing the control copy at the same fixture project's second plan.
    await page.goto(
      '/plan-detail/.ralph-workspace%2Fplans%2Fteam-a%2FPLAN-widget.plan.md' +
        '?projectRoot=' +
        encodeURIComponent(FIXTURE_ROOT) +
        '&controlCopy=' +
        encodeURIComponent('.ralph-workspace/plans/team-b/PLAN-widget.plan.md'),
    );
    await page.waitForSelector('.plan-detail');
    const diffSegment = page.locator('ion-segment-button[value="diff"]');
    await expect(diffSegment).toHaveJSProperty('disabled', false);
  });

  test('3. resume a waiting run from the Runs index in two interactions', async ({ page }) => {
    const tracking = trackFailures(page);
    await page.goto('/runs');
    await page.waitForSelector('[data-testid="runs-inventory"]');

    const waitingRow = page.locator('.runs-table .data-table-row', { hasText: 'run-waiting-approval' }).first();
    await expect(waitingRow).toBeVisible();
    await waitingRow.locator('a.run-id').click();

    await page.waitForSelector('[data-testid="run-detail-page"]');
    await expect(page.locator('[data-testid="run-state"]')).toContainText(/waiting/i);
    await expect(page.locator('[data-testid="next-action-panel"]')).toBeVisible();

    expect(tracking.consoleErrors, tracking.consoleErrors.join('\n')).toEqual([]);
  });

  test('4. inspect an approval and see the respond path without reading raw logs', async ({ page }) => {
    await page.goto('/workflows/runs/run-waiting-approval');
    await page.waitForSelector('[data-testid="run-detail-page"]');

    const actionCard = page.locator('[data-testid="pending-action-req-approve-1"]');
    await expect(actionCard).toBeVisible();
    await expect(actionCard.locator('.question')).toContainText('Approve the generated implementation plan');
    await expect(page.locator('[data-testid="respond-req-approve-1-approve"]')).toBeEnabled();
    await expect(page.locator('text=/agent\\.log/i')).toHaveCount(0);
  });

  test('5. understand a workflow topology from the graph', async ({ page }) => {
    await page.goto('/workflows/feature-delivery');
    await page.waitForLoadState('networkidle');
    // The project override's overview text should be visible, proving source
    // precedence resolved to the project scope, not the bundled definition.
    await expect(page.getByText('PROJECT OVERRIDE (acceptance fixture)')).toBeVisible();
  });

  test('6. inspect a failed verification', async ({ page }) => {
    await page.goto('/workflows/runs/run-failed-verification');
    await page.waitForSelector('[data-testid="run-detail-page"]');
    await expect(page.locator('[data-testid="run-state"]')).toContainText(/failed/i);
  });

  test('7. rework history is visible on a run with a prior request-changes verdict', async ({ page }) => {
    await page.goto('/workflows/runs/run-rework');
    await page.waitForSelector('[data-testid="run-detail-page"]');
    await expect(page.locator('[data-testid="stage-implement"] [data-testid="stage-attempt"]')).toContainText('2');
  });

  test('8. usage volume is reachable only when entering Insights, not from Home or Plans', async ({ page }) => {
    const usageRequests: string[] = [];
    page.on('request', (req) => {
      if (/\/api\/metrics\//.test(req.url())) {
        usageRequests.push(req.url());
      }
    });

    await page.goto('/home');
    await page.waitForSelector('[data-testid="home-inventory"], [data-testid="home-empty"]');
    await page.goto('/plans');
    await page.waitForSelector('[data-testid="plans-inventory"]');
    expect(usageRequests, `unexpected usage requests before entering Insights: ${usageRequests.join(', ')}`).toEqual([]);

    await page.goto('/insights');
    await page.waitForLoadState('networkidle');
    expect(usageRequests.length).toBeGreaterThan(0);
  });

  test('no horizontal overflow at 390px across the acceptance journeys', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    for (const path of ['/home', '/plans', '/runs', '/workflows/runs/run-waiting-approval', '/insights']) {
      await page.goto(path);
      await page.waitForLoadState('networkidle');
      const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
      expect(scrollWidth, `${path} overflows at 390px (scrollWidth=${scrollWidth})`).toBeLessThanOrEqual(390);
    }
  });
});
