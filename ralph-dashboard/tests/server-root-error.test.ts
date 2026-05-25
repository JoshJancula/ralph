import '@angular/compiler';
import { jest } from '@jest/globals';

const originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';

describe('server root route error handling', () => {
  let app: typeof import('../src/server').app;
  let isSendFileNotFoundError: typeof import('../src/server')['isSendFileNotFoundError'];

  beforeAll(async () => {
    ({ app } = await import('../src/server'));
  });

  afterAll(() => {
    if (originalSkipListen === undefined) {
      delete process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    } else {
      process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = originalSkipListen;
    }
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  function createMockResponse(sendFileError?: { code?: string; message?: string }) {
    return {
      body: '',
      sentFile: '',
      statusCode: 0,
      headersSent: false,
      status(code: number) {
        this.statusCode = code;
        return this;
      },
      send(body: string) {
        this.body = body;
        return this;
      },
      sendFile(filePath: string, optionsOrCallback?: unknown, callback?: (error?: unknown) => void) {
        this.sentFile = filePath;
        const cb = typeof optionsOrCallback === 'function' ? optionsOrCallback : callback;
        if (cb) {
          cb(sendFileError ? { ...sendFileError } : undefined);
        }
        return this;
      },
    };
  }

  function findRootHandler(): ((req: unknown, res: unknown) => void) | null {
    const stack = (app as any)._router?.stack;
    if (!stack) return null;
    for (const layer of stack) {
      if (layer.route?.path === '/' && layer.route?.methods?.get) {
        return layer.route.stack[0].handle;
      }
    }
    return null;
  }

  it('returns 404 when index.csr.html is missing (ENOENT)', () => {
    const handler = findRootHandler();
    if (!handler) return;

    const res = createMockResponse({ code: 'ENOENT', message: 'no such file' });
    handler({}, res);

    expect(res.statusCode).toBe(404);
    expect(res.body).toBe('Not found');
  });

  it('returns 404 when index.csr.html is missing (NotFoundError)', () => {
    const handler = findRootHandler();
    if (!handler) return;

    const res = createMockResponse({ name: 'NotFoundError', message: 'Not Found' } as any);
    handler({}, res);

    expect(res.statusCode).toBe(404);
    expect(res.body).toBe('Not found');
  });

  it('returns 500 on non-ENOENT sendFile error', () => {
    const handler = findRootHandler();
    if (!handler) return;

    const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const res = createMockResponse({ code: 'EACCES', message: 'permission denied' });
    handler({}, res);

    expect(res.statusCode).toBe(500);
    expect(res.body).toBe('Internal server error');
    expect(consoleErrorSpy).toHaveBeenCalledWith('Error serving index:', 'permission denied');
  });

  it('does not send 500 when headers already sent on non-ENOENT error', () => {
    const handler = findRootHandler();
    if (!handler) return;

    const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const res = createMockResponse({ code: 'EACCES', message: 'permission denied' });
    res.headersSent = true;
    res.statusCode = 200;
    handler({}, res);

    expect(consoleErrorSpy).toHaveBeenCalledWith('Error serving index:', 'permission denied');
    expect(res.statusCode).toBe(200);
  });
});