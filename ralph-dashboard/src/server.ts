import {
  AngularNodeAppEngine,
  createNodeRequestHandler,
  writeResponseToNodeResponse,
} from '@angular/ssr/node';
import express, { type Request, type Response } from 'express';
import { existsSync } from 'node:fs';
import { mkdir, readFile, unlink, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { registerDashboardApi } from './server/dashboard-api';
import { registerWorkflowApi } from './server/workflow-api';
import { registerSafetyApi } from './server/safety-api';
import { registerTaskScheduleApi, startDashboardScheduler } from './server/task-schedule-api';

function resolveBrowserDistFolder(): string {
  const envDir = process.env['RALPH_DASHBOARD_BROWSER_DIST']?.trim();
  if (envDir) {
    return resolve(envDir);
  }
  const moduleDir = dirname(fileURLToPath(import.meta.url));
  const fromModule = resolve(moduleDir, '..', 'browser');
  if (existsSync(join(fromModule, 'index.csr.html'))) {
    return fromModule;
  }
  const fromProject = resolve(process.cwd(), 'dist', 'ralph-dashboard', 'browser');
  if (existsSync(join(fromProject, 'index.csr.html'))) {
    return fromProject;
  }
  return fromModule;
}

const browserDistFolder = resolveBrowserDistFolder();
// Express uses `send`; absolute paths containing a segment like `$HOME/.ralph` are classified as dotfiles unless allowed.
const csrShellSendFileOptions = { dotfiles: 'allow' as const };
const shouldServeSpaShell = (pathname: string): boolean => !/^\/api(?:\/|$)/.test(pathname);
type ErrorWithMessage = { message?: string } | null | undefined;
type SendFileError = { message?: string; code?: string; status?: number; statusCode?: number } | null | undefined;

export const app = express();
registerDashboardApi(app);
registerWorkflowApi(app);
registerSafetyApi(app);
registerTaskScheduleApi(app);
startDashboardScheduler(app);

// Serve `/` before express.static: otherwise serve-static treats `/` as the browser root
// directory; with `redirect: false` it responds 404 for directory access and the CSR shell
// never runs (see serve-static `createNotFoundDirectoryListener`).

let angularApp: AngularNodeAppEngine | null = null;

const initializeAngularApp = () => {
  if (!angularApp) {
    try {
      angularApp = new AngularNodeAppEngine();
    } catch (error) {
      // Silently fall back to client rendering if manifest is not set
      return {
        handle: async () => null,
      } as any;
    }
  }
  return angularApp;
};

export function logErrorMessage(prefix: string, error: ErrorWithMessage): void {
  console.error(prefix, error?.message);
}

function isSendFileNotFoundError(error: SendFileError): boolean {
  if (!error) {
    return false;
  }
  if (error.code === 'ENOENT' || error.status === 404 || error.statusCode === 404) {
    return true;
  }
  // Express 5 / send may surface missing files as NotFoundError instead of ENOENT.
  const named = error as { name?: string };
  return named.name === 'NotFoundError';
}

export function startDashboardServer(
  port = Number(process.env['PORT'] ?? 8123),
  host = process.env['HOST'] ?? '127.0.0.1',
) {
  const configHome = process.env['XDG_CONFIG_HOME']?.trim() || join(homedir(), '.config');
  const endpointPath = join(configHome, 'ralph', 'dashboard', 'endpoint.json');
  const startedAt = new Date().toISOString();
  let endpointWrite = Promise.resolve();
  let shuttingDown = false;

  const removeEndpoint = async () => {
    try {
      const current = JSON.parse(await readFile(endpointPath, 'utf8')) as { pid?: number; startedAt?: string };
      if (current.pid !== process.pid || current.startedAt !== startedAt) {
        return;
      }
      await unlink(endpointPath);
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== 'ENOENT') {
        console.error(`Dashboard endpoint record could not be removed: ${(error as Error).message}`);
      }
    }
  };

  const server = app.listen(port, host, () => {
    const address = server.address();
    const boundHost = address && typeof address === 'object' ? address.address : host;
    const boundPort = address && typeof address === 'object' ? address.port : port;
    endpointWrite = mkdir(dirname(endpointPath), { recursive: true })
      .then(() => writeFile(endpointPath, JSON.stringify({
        host: boundHost,
        port: boundPort,
        pid: process.pid,
        startedAt,
      }, null, 2) + '\n'))
      .catch((error: Error) => {
        console.error(`Dashboard endpoint record could not be written: ${error.message}`);
      });

    console.log(`Node Express server listening on http://${boundHost}:${boundPort}`);
    console.log(`Dashboard CSR bundle directory: ${browserDistFolder}`);
  });

  server.once('close', () => {
    void endpointWrite.then(removeEndpoint);
  });

  const shutdown = () => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    server.close(() => {
      void endpointWrite.then(removeEndpoint).finally(() => {
        process.exitCode = 0;
      });
    });
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
  server.once('close', () => {
    process.removeListener('SIGINT', shutdown);
    process.removeListener('SIGTERM', shutdown);
  });

  server.on('error', (error: NodeJS.ErrnoException) => {
    if (error.code === 'EADDRINUSE') {
      console.error(
        `Dashboard server could not bind to ${host}:${port}: address already in use. Set PORT or HOST to use a different address.`,
      );
      process.exitCode = 1;
      return;
    }

    console.error(`Dashboard server failed to start on ${host}:${port}:`, error.message);
    process.exitCode = 1;
  });

  return server;
}

app.get('/', (req, res) => {
  res.sendFile(join(browserDistFolder, 'index.csr.html'), csrShellSendFileOptions, (err) => {
    if (!err) {
      return;
    }

    if (isSendFileNotFoundError(err as SendFileError)) {
      res.status(404).send('Not found');
      return;
    }

    logErrorMessage('Error serving index:', err as ErrorWithMessage);
    if (!res.headersSent) {
      res.status(500).send('Internal server error');
    }
  });
});

app.use(
  express.static(browserDistFolder, {
    maxAge: '1d',
    index: false,
    redirect: false,
    setHeaders(res: Response) {
      res.setHeader('X-Content-Type-Options', 'nosniff');
    },
  }),
);

app.use((req, res, next) => {
  try {
    const engine = initializeAngularApp();
    engine
      .handle(req)
      .then((response: any) => {
        if (response && res && typeof res.setHeader === 'function') {
          writeResponseToNodeResponse(response, res);
        } else {
          next();
        }
      })
      .catch((error: ErrorWithMessage) => {
        logErrorMessage('Error handling request:', error);
        next(error);
      });
  } catch (error) {
    logErrorMessage('Error initializing Angular app:', error as ErrorWithMessage);
    next(error);
  }
});

export function handleSpaFallback(req: Request, res: Response): void {
  if (!shouldServeSpaShell(req.path)) {
    res.status(404).send('Not found');
    return;
  }

  const indexPath = join(browserDistFolder, 'index.csr.html');
  res.status(200);
  res.sendFile(indexPath, csrShellSendFileOptions, (err) => {
    if (!err) {
      return;
    }

    if (isSendFileNotFoundError(err as SendFileError)) {
      res.status(404).send('Not found');
      return;
    }

    logErrorMessage('Error serving SPA shell:', err as ErrorWithMessage);
    res.status(500).send('Internal server error');
  });
}

// Fallback: serve the CSR entrypoint for SPA routes, but 404 API misses.
app.use(handleSpaFallback);

if (process.env['RALPH_DASHBOARD_SKIP_LISTEN'] !== '1') {
  startDashboardServer();
}

export const reqHandler = createNodeRequestHandler(app);

export default reqHandler;
