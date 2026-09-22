import { test, expect, type Page } from '@playwright/test';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Visual baseline capture for dashboard-ui-polish TODO 1.
 * Screenshots and layout probes land under
 * .ralph-workspace/artifacts/dashboard-ui-polish.plan/baseline/
 * Assertions stay limited to "page rendered" so this spec documents the
 * current UI rather than enforcing a polished state.
 */

const OUT = join(__dirname, '..', '..', '.ralph-workspace', 'artifacts', 'dashboard-ui-polish.plan', 'baseline');

const ROUTES: Array<{ name: string; path: string; ready: string }> = [
  { name: 'home', path: '/home', ready: '[data-testid="home-inventory"], [data-testid="home-empty"]' },
  { name: 'plans', path: '/plans', ready: '[data-testid="plans-inventory"], [data-testid="plans-empty"]' },
  { name: 'runs', path: '/runs', ready: '[data-testid="runs-inventory"], [data-testid="runs-empty"]' },
  { name: 'workflows', path: '/workflows', ready: '[data-testid="workflows-inventory"], [data-testid="workflows-empty"]' },
  { name: 'insights', path: '/insights', ready: 'ralph-usage-hub' },
];

type Probe = {
  route: string;
  viewport: string;
  width: number;
  scrollWidth: number;
  overflowPx: number;
  headings: string[];
  smallTapTargets: number;
  mutedTextSamples: string[];
  bodyText: string;
};

async function settle(page: Page, path: string, ready: string): Promise<void> {
  await page.goto(path);
  await page.waitForSelector(ready, { timeout: 20_000 });
  await page.waitForLoadState('networkidle');
}

async function probe(page: Page, route: string, viewport: string, width: number): Promise<Probe> {
  return page.evaluate(
    ({ routeName, viewportLabel, viewportWidth }) => {
      const headings = Array.from(document.querySelectorAll('h1, h2, h3, h4')).map((el) => {
        const tag = el.tagName.toLowerCase();
        const text = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80);
        return `${tag}: ${text}`;
      });

      const interactive = Array.from(
        document.querySelectorAll('a, button, input, select, textarea, [role="button"]'),
      );
      let smallTapTargets = 0;
      for (const el of interactive) {
        const style = window.getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') continue;
        const rect = el.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0) continue;
        if (rect.width < 44 || rect.height < 44) smallTapTargets += 1;
      }

      const mutedTextSamples: string[] = [];
      for (const el of Array.from(document.querySelectorAll('p, span, .muted, .lede, .hint'))) {
        const color = window.getComputedStyle(el).color;
        const text = (el.textContent || '').replace(/\s+/g, ' ').trim();
        if (text && mutedTextSamples.length < 6 && (color.includes('139') || color.includes('8b949e') || el.className.toString().includes('muted'))) {
          mutedTextSamples.push(`${text.slice(0, 70)} [${color}]`);
        }
      }

      return {
        route: routeName,
        viewport: viewportLabel,
        width: viewportWidth,
        scrollWidth: document.documentElement.scrollWidth,
        overflowPx: Math.max(0, document.documentElement.scrollWidth - viewportWidth),
        headings,
        smallTapTargets,
        mutedTextSamples,
        bodyText: (document.body.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 400),
      };
    },
    { routeName: route, viewportLabel: viewport, viewportWidth: width },
  );
}

test.describe('UI baseline capture', () => {
  test('capture Home, Plans, Runs, Workflows, Insights at desktop and mobile', async ({ page }, testInfo) => {
    test.skip(!process.env['RALPH_UI_BASELINE'], 'Set RALPH_UI_BASELINE=1 to write polish baseline screenshots');
    test.setTimeout(180_000);
    mkdirSync(OUT, { recursive: true });
    const probes: Probe[] = [];

    for (const viewport of [
      { label: 'desktop-1440', width: 1440, height: 900 },
      { label: 'mobile-390', width: 390, height: 844 },
    ]) {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });

      for (const route of ROUTES) {
        await settle(page, route.path, route.ready);
        const shot = join(OUT, `${route.name}-${viewport.label}.png`);
        await page.screenshot({ path: shot, fullPage: true });
        const viewportShot = join(OUT, `${route.name}-${viewport.label}-viewport.png`);
        await page.screenshot({ path: viewportShot, fullPage: false });
        probes.push(await probe(page, route.name, viewport.label, viewport.width));
      }
    }

    writeFileSync(join(OUT, 'layout-probes.json'), JSON.stringify(probes, null, 2));
    writeFileSync(
      join(OUT, 'manifest.md'),
      [
        '# Baseline screenshot manifest',
        '',
        `Captured: ${new Date().toISOString()}`,
        `Playwright project: ${testInfo.project.name}`,
        `Fixture workspace: e2e/fixtures/acceptance-workspace`,
        '',
        'Files:',
        ...ROUTES.flatMap((route) => [
          `- ${route.name}-desktop-1440.png (full page)`,
          `- ${route.name}-desktop-1440-viewport.png`,
          `- ${route.name}-mobile-390.png (full page)`,
          `- ${route.name}-mobile-390-viewport.png`,
        ]),
        '',
      ].join('\n'),
    );

    expect(probes).toHaveLength(ROUTES.length * 2);
    for (const item of probes) {
      expect(item.bodyText.length, `${item.route} ${item.viewport} rendered no text`).toBeGreaterThan(20);
    }
  });
});
