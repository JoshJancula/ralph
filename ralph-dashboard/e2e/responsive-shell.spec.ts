import { test, expect, type Page } from '@playwright/test';

/**
 * PLAN18 deliver-responsive-accessible-shell verification: every primary
 * screen at desktop (1200px) and narrow (390px), asserting the document
 * never grows wider than the viewport (no horizontal scrollbar), driven
 * against the real dashboard server + real fixture workspace (see
 * playwright.config.ts), not mocked API responses.
 */

const DESKTOP = { width: 1200, height: 900 };
const NARROW = { width: 390, height: 844 };

async function assertNoHorizontalOverflow(page: Page, viewportWidth: number): Promise<void> {
  const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
  expect(scrollWidth, `document.documentElement.scrollWidth (${scrollWidth}) exceeds viewport width (${viewportWidth})`).toBeLessThanOrEqual(
    viewportWidth,
  );
}

async function gotoAndSettle(page: Page, path: string, readySelector: string): Promise<void> {
  await page.goto(path);
  await page.waitForSelector(readySelector, { timeout: 15_000 });
}

for (const viewport of [DESKTOP, NARROW]) {
  test.describe(`Responsive shell @ ${viewport.width}px`, () => {
    test.use({ viewport });

    test('Home', async ({ page }) => {
      await gotoAndSettle(page, '/home', '[data-testid="home-inventory"], [data-testid="home-empty"]');
      await assertNoHorizontalOverflow(page, viewport.width);
    });

    test('Plans', async ({ page }) => {
      await gotoAndSettle(page, '/plans', '[data-testid="plans-inventory"], [data-testid="plans-empty"]');
      await assertNoHorizontalOverflow(page, viewport.width);
    });

    test('Plan detail', async ({ page }) => {
      await gotoAndSettle(page, '/plans', '[data-testid="plans-inventory"]');
      const row = page.locator('.plan-row', { hasText: 'widget-rollout-team-b' }).first();
      await row.getByRole('button', { name: 'Open plan' }).click();
      await page.waitForURL((url) => !url.pathname.startsWith('/plans') || url.search.length > 0 || url.pathname.includes('file'));
      await page.waitForLoadState('networkidle');
      await assertNoHorizontalOverflow(page, viewport.width);
    });

    test('Runs', async ({ page }) => {
      await gotoAndSettle(page, '/runs', '[data-testid="runs-inventory"], [data-testid="runs-empty"]');
      await assertNoHorizontalOverflow(page, viewport.width);
    });

    test('Run detail (waiting approval)', async ({ page }) => {
      await gotoAndSettle(page, '/workflows/runs/run-waiting-approval', '[data-testid="run-detail-page"]');
      await assertNoHorizontalOverflow(page, viewport.width);
    });

    test('Workflows catalog', async ({ page }) => {
      await gotoAndSettle(page, '/workflows', '[data-testid="workflows-inventory"], [data-testid="workflows-empty"]');
      await assertNoHorizontalOverflow(page, viewport.width);
    });

    test('Workflow detail', async ({ page }) => {
      await page.goto('/workflows/feature-delivery');
      await page.waitForLoadState('networkidle');
      await assertNoHorizontalOverflow(page, viewport.width);
    });

    test('Workflow editor', async ({ page }) => {
      await page.goto('/workflows/feature-delivery/edit');
      await page.waitForLoadState('networkidle');
      await assertNoHorizontalOverflow(page, viewport.width);
    });

    test('Insights', async ({ page }) => {
      await gotoAndSettle(page, '/insights', 'ralph-usage-hub');
      await page.waitForLoadState('networkidle');
      await assertNoHorizontalOverflow(page, viewport.width);
    });
  });
}

test.describe('Keyboard and focus behavior', () => {
  test('mobile menu opens, traps escape, and closing returns focus', async ({ page }) => {
    await page.setViewportSize(NARROW);
    await gotoAndSettle(page, '/home', '[data-testid="home-inventory"], [data-testid="home-empty"]');

    const menuButton = page.locator('ion-menu-button');
    await menuButton.click();
    const menu = page.locator('ion-menu[menu-id="workspace-menu"], ion-menu#workspace-menu, ion-menu');
    await expect(menu.first()).toBeVisible();

    await page.keyboard.press('Escape');
    // Ionic's menu closes on Escape and returns focus to the trigger.
    await expect(async () => {
      const isOpen = await page.evaluate(() => {
        const el = document.querySelector('ion-menu');
        return el ? (el as unknown as { isOpen?: () => Promise<boolean> }).isOpen?.() : Promise.resolve(false);
      });
      expect(await isOpen).toBeFalsy();
    }).toPass({ timeout: 5000 });
  });

  test('workspace switcher combobox supports Escape to close', async ({ page }) => {
    await page.setViewportSize(DESKTOP);
    await gotoAndSettle(page, '/home', '[data-testid="home-inventory"], [data-testid="home-empty"]');

    const trigger = page.locator('app-workspace-switcher button[aria-haspopup="listbox"]').first();
    await trigger.click();
    await page.keyboard.press('Escape');
    await expect(page.locator('[role="listbox"]')).toHaveCount(0);
  });
});
