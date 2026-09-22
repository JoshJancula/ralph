import { test, expect } from '@playwright/test';
import { enrichWorkflowRunDetail } from '../src/server/workflow-run-detail';

const BASE_URL = 'http://localhost:4200';

function waitingDetailPayload() {
  return enrichWorkflowRunDetail(
    {
      schemaVersion: 1,
      run: {
        runId: 'run-test-waiting',
        workflowId: 'feature-delivery',
        mode: 'sequential',
        state: 'waiting',
        createdAt: '2026-09-14T10:00:00Z',
        updatedAt: '2026-09-14T10:05:00Z',
      },
      stages: [
        {
          id: 'human-gate',
          state: 'waiting',
          stageKind: 'approval',
          attempt: 1,
          requestId: 'req-wait-1',
          requestState: 'outstanding',
          createdAt: '2026-09-14T10:02:00Z',
          updatedAt: '2026-09-14T10:02:00Z',
        },
      ],
      diagnosis: {
        state: 'waiting',
        reasonCode: 'human-approval',
        summary: 'Approve the plan before resume',
        stageId: 'human-gate',
        requestKind: 'approval',
        requestId: 'req-wait-1',
        evidence: [],
        retryable: false,
        nextAction: { label: 'answer the outstanding request', argv: ['ralph', 'workflow', 'actions', 'list', 'run-test-waiting'] },
      },
      nextAction: { label: 'answer the outstanding request', argv: ['ralph', 'workflow', 'actions', 'list', 'run-test-waiting'] },
    },
    [
      {
        requestId: 'req-wait-1',
        kind: 'approval',
        stageId: 'human-gate',
        question: 'Approve the generated plan?',
        status: 'outstanding',
        choices: ['approve', 'request-changes', 'cancel'],
        createdAt: '2026-09-14T10:02:00Z',
      },
    ],
  );
}

test.describe('Workflow Run Detail — waiting action path', () => {
  test.beforeEach(async ({ page }) => {
    await page.route('**/api/capabilities', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ workflowWrites: true, workflowRuns: true, assistant: true }),
      });
    });
    await page.route('**/api/workflow-runs/run-test-waiting**', async (route) => {
      if (route.request().method() !== 'GET') {
        await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true }) });
        return;
      }
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(waitingDetailPayload()),
      });
    });
  });

  test('waiting action shows respond and resume path without reading raw logs', async ({ page }) => {
    await page.setViewportSize({ width: 1200, height: 800 });
    await page.goto(`${BASE_URL}/workflows/runs/run-test-waiting`);
    await page.waitForSelector('[data-testid="run-detail-page"]');

    await expect(page.locator('[data-testid="run-state"]')).toContainText(/waiting/i);
    await expect(page.locator('[data-testid="next-action-panel"]')).toBeVisible();
    await expect(page.locator('[data-testid="next-action-label"]')).toBeVisible();

    const actionCard = page.locator('[data-testid="pending-action-req-wait-1"]');
    await expect(actionCard).toBeVisible();
    await expect(actionCard.locator('.question')).toContainText('Approve the generated plan?');

    const approveBtn = page.locator('[data-testid="respond-req-wait-1-approve"]');
    await expect(approveBtn).toBeEnabled();

    const resumeBtn = page.locator('[data-testid="run-resume"]');
    await expect(resumeBtn).toBeVisible();

    // Operator path is readable from the stage map / next action — not from raw logs.
    await expect(page.locator('[data-testid="stages-section"]')).toBeVisible();
    await expect(page.locator('text=/raw log|agent\\.log/i')).toHaveCount(0);
  });

  test('no horizontal overflow at 390px for waiting detail', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(`${BASE_URL}/workflows/runs/run-test-waiting`);
    await page.waitForSelector('[data-testid="run-detail-page"]');
    const box = await page.locator('[data-testid="run-detail-page"]').boundingBox();
    expect(box?.width ?? 999).toBeLessThanOrEqual(390);
  });
});
