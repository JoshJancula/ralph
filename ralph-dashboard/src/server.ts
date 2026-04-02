import {
  AngularNodeAppEngine,
  createNodeRequestHandler,
  writeResponseToNodeResponse,
} from '@angular/ssr/node';
import express from 'express';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { registerDashboardApi } from './server/dashboard-api';

const serverDir = dirname(fileURLToPath(import.meta.url));
const browserDistFolder = join(serverDir, '../browser');

const app = express();
registerDashboardApi(app);

let angularApp: AngularNodeAppEngine | null = null;

const initializeAngularApp = () => {
  if (!angularApp) {
    angularApp = new AngularNodeAppEngine();
  }
  return angularApp;
};

app.use(
  express.static(browserDistFolder, {
    maxAge: '1y',
    index: false,
    redirect: false,
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
      .then((response) => {
        if (response) {
          writeResponseToNodeResponse(response, res);
        } else {
          next();
        }
      })
      .catch((error) => {
        console.error('Error handling request:', error);
        next(error);
      });
  } catch (error) {
    console.error('Error initializing Angular app:', error);
    next(error);
  }
});

// Fallback: serve index.html for all unhandled requests (SPA routing)
app.use((req, res) => {
  const indexPath = join(browserDistFolder, 'index.html');
  res.sendFile(indexPath, (err) => {
    if (err) {
      res.status(404).send('Not found');
    }
  });
});

const port = Number(process.env['PORT'] ?? 8123);
app.listen(port, '127.0.0.1', () => {
  console.log(`Node Express server listening on http://localhost:${port}`);
});

export const reqHandler = createNodeRequestHandler(app);

export default reqHandler;
