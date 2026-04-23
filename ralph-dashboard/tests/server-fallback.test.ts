import '@angular/compiler';
import { jest } from '@jest/globals';

const originalSkipListen = process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
const originalHost = process.env['HOST'];
const originalPort = process.env['PORT'];
const originalExitCode = process.exitCode;
process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = '1';

describe('server fallback routing', () => {
  let app: typeof import('../src/server').app;
  let handleSpaFallback: typeof import('../src/server').handleSpaFallback;
  let logErrorMessage: typeof import('../src/server').logErrorMessage;
  let startDashboardServer: typeof import('../src/server').startDashboardServer;

  beforeAll(async () => {
    ({ app, handleSpaFallback, logErrorMessage, startDashboardServer } = await import('../src/server'));
  });

  afterEach(() => {
    jest.restoreAllMocks();
    process.exitCode = originalExitCode;
  });

  afterAll(() => {
    if (originalSkipListen === undefined) {
      delete process.env['RALPH_DASHBOARD_SKIP_LISTEN'];
    } else {
      process.env['RALPH_DASHBOARD_SKIP_LISTEN'] = originalSkipListen;
    }
    if (originalHost === undefined) {
      delete process.env['HOST'];
    } else {
      process.env['HOST'] = originalHost;
    }
    if (originalPort === undefined) {
      delete process.env['PORT'];
    } else {
      process.env['PORT'] = originalPort;
    }
  });

  it('returns 404 for missing API paths instead of the SPA shell', async () => {
    const response = createMockResponse();

    handleSpaFallback({ path: '/api/does-not-exist' } as any, response as any);

    expect(response.statusCode).toBe(404);
    expect(response.body).toBe('Not found');
    expect(response.sentFile).toBe('');
  });

  it('serves the CSR shell for SPA routes', () => {
    const response = createMockResponse();

    handleSpaFallback({ path: '/plans/implement-findings-from-review' } as any, response as any);

    expect(response.statusCode).toBe(200);
    expect(response.sentFile).toContain('index.csr.html');
  });

  it('logs only the error message for handled server errors', () => {
    const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    logErrorMessage('Error handling request:', {
      message: 'boom',
      stack: 'stack trace should not be logged',
    });

    expect(consoleErrorSpy).toHaveBeenCalledWith('Error handling request:', 'boom');
  });

  it('returns 404 for missing CSR shell files without logging', () => {
    const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const response = createMockResponse({
      code: 'ENOENT',
      message: 'no such file or directory',
    });

    handleSpaFallback({ path: '/plans/implement-findings-from-review' } as any, response as any);

    expect(response.statusCode).toBe(404);
    expect(response.body).toBe('Not found');
    expect(consoleErrorSpy).not.toHaveBeenCalled();
  });

  it('returns 500 for other CSR shell errors and logs only the message', () => {
    const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const response = createMockResponse({
      code: 'EACCES',
      message: 'permission denied',
    });

    handleSpaFallback({ path: '/plans/implement-findings-from-review' } as any, response as any);

    expect(response.statusCode).toBe(500);
    expect(response.body).toBe('Internal server error');
    expect(consoleErrorSpy).toHaveBeenCalledWith('Error serving SPA shell:', 'permission denied');
  });

  it('binds to HOST when starting the server', () => {
    const server = createMockListenServer();
    const listenSpy = jest.spyOn(app as any, 'listen').mockReturnValue(server as any);
    const previousHost = process.env['HOST'];
    const previousPort = process.env['PORT'];

    process.env['HOST'] = '0.0.0.0';
    process.env['PORT'] = '9123';

    try {
      startDashboardServer();

      expect(listenSpy).toHaveBeenCalledWith(9123, '0.0.0.0', expect.any(Function));
    } finally {
      if (previousHost === undefined) {
        delete process.env['HOST'];
      } else {
        process.env['HOST'] = previousHost;
      }
      if (previousPort === undefined) {
        delete process.env['PORT'];
      } else {
        process.env['PORT'] = previousPort;
      }
    }
  });

  it('logs a clear message when the port is already in use', () => {
    const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const server = createMockListenServer();
    jest.spyOn(app as any, 'listen').mockReturnValue(server as any);

    startDashboardServer(8123, '127.0.0.1');
    server.emit('error', { code: 'EADDRINUSE', message: 'listen EADDRINUSE' });

    expect(consoleErrorSpy).toHaveBeenCalledWith(
      'Dashboard server could not bind to 127.0.0.1:8123: address already in use. Set PORT or HOST to use a different address.',
    );
    expect(process.exitCode).toBe(1);
  });
});

function createMockResponse(sendFileError?: { code?: string; message?: string }) {
  return {
    body: '',
    sentFile: '',
    statusCode: 0,
    status(code: number) {
      this.statusCode = code;
      return this;
    },
    send(body: string) {
      this.body = body;
      return this;
    },
    sendFile(filePath: string, callback?: (error?: unknown) => void) {
      this.sentFile = filePath;
      callback?.(sendFileError);
      return this;
    },
  };
}

function createMockListenServer() {
  const handlers: Record<string, (error?: unknown) => void> = {};

  const server = {
    on: jest.fn((event: string, handler: (error?: unknown) => void) => {
      handlers[event] = handler;
      return server;
    }),
    emit(event: string, error?: unknown) {
      handlers[event]?.(error);
    },
  };

  return server;
}
