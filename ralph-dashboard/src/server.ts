import {
  AngularNodeAppEngine,
  createNodeRequestHandler,
  writeResponseToNodeResponse,
} from '@angular/ssr/node';
import express, { type Request, type Response } from 'express';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { registerDashboardApi } from './server/dashboard-api';

const serverDir = dirname(fileURLToPath(import.meta.url));
const browserDistFolder = join(serverDir, '../browser');
const shouldServeSpaShell = (pathname: string): boolean => !/^\/api(?:\/|$)/.test(pathname);
type ErrorWithMessage = { message?: string } | null | undefined;
type SendFileError = { message?: string; code?: string; status?: number; statusCode?: number } | null | undefined;

export const app = express();
registerDashboardApi(app);

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
  return error?.code === 'ENOENT' || error?.status === 404 || error?.statusCode === 404;
}

export function startDashboardServer(
  port = Number(process.env['PORT'] ?? 8123),
  host = process.env['HOST'] ?? '127.0.0.1',
) {
  const server = app.listen(port, host, () => {
    console.log(`Node Express server listening on http://${host}:${port}`);
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

// Serve index.csr.html for root path
app.get('/', (req, res) => {
  res.sendFile(join(browserDistFolder, 'index.csr.html'));
});

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
  res.sendFile(indexPath, (err) => {
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
