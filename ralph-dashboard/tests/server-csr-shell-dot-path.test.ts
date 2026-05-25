import '@angular/compiler';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { jest } from '@jest/globals';

const originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
const originalBrowserDist = process.env['RALPH_DASHBOARD_BROWSER_DIST'];

describe('CSR shell when browser dist path crosses a dot-directory segment', () => {
  afterEach(() => {
    jest.resetModules();

    if (originalSkipListen === undefined) {
      delete process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    } else {
      process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = originalSkipListen;
    }

    if (originalBrowserDist === undefined) {
      delete process.env['RALPH_DASHBOARD_BROWSER_DIST'];
    } else {
      process.env['RALPH_DASHBOARD_BROWSER_DIST'] = originalBrowserDist;
    }
  });

  it('serves GET / with 200 when RALPH_DASHBOARD_BROWSER_DIST is under a .segment dir', async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'dash-dot-path-'));
    const browserDir = join(tmp, '.ralphmirror', 'dist', 'ralph-dashboard', 'browser');

    mkdirSync(browserDir, { recursive: true });
    writeFileSync(join(browserDir, 'index.csr.html'), '<!doctype html><title>csr-dot-path</title>');

    try {
      jest.resetModules();
      process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
      process.env['RALPH_DASHBOARD_BROWSER_DIST'] = browserDir;

      const { handleSpaFallback } = await import('../src/server');
      const response = createMockResponse();
      handleSpaFallback({ path: '/' } as any, response as any);
      expect(response.statusCode).toBe(200);
      expect(response.text).toContain('<title>csr-dot-path</title>');
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it('serves SPA deep link when browser dist crosses a dot-directory segment', async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'dash-dot-path-spa-'));
    const browserDir = join(tmp, '.hiddeninstall', 'browser');

    mkdirSync(browserDir, { recursive: true });
    writeFileSync(join(browserDir, 'index.csr.html'), '<!doctype html><title>csr-spa</title>');

    try {
      jest.resetModules();
      process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';
      process.env['RALPH_DASHBOARD_BROWSER_DIST'] = browserDir;

      const { handleSpaFallback } = await import('../src/server');
      const response = createMockResponse();
      handleSpaFallback({ path: '/plans/some-plan' } as any, response as any);
      expect(response.statusCode).toBe(200);
      expect(response.text).toContain('<title>csr-spa</title>');
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });
});

function createMockResponse(sendFileError?: { code?: string; message?: string }) {
  return {
    body: '',
    text: '',
    sentFile: '',
    sendFileOptions: undefined as Record<string, unknown> | undefined,
    statusCode: 0,
    status(code: number) {
      this.statusCode = code;
      return this;
    },
    send(body: string) {
      this.body = body;
      this.text = body;
      return this;
    },
    sendFile(filePath: string, optionsOrCallback?: unknown, callback?: (error?: unknown) => void) {
      this.sentFile = filePath;
      const cb = typeof optionsOrCallback === 'function' ? optionsOrCallback : callback;
      if (
        typeof optionsOrCallback === 'object' &&
        optionsOrCallback !== null &&
        typeof cb === 'function'
      ) {
        this.sendFileOptions = optionsOrCallback as Record<string, unknown>;
      }
      cb?.(sendFileError);
      if (!sendFileError) {
        const content = readFileSync(filePath, 'utf8');
        this.body = content;
        this.text = content;
      }
      return this;
    },
  };
}
