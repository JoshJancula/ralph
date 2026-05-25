// Load the CommonJS stub to set up Angular manifests
require('./angular-launch-server-stub.cjs');

const path = require('node:path');

// Bundled server chunks may not resolve ../browser the same as this launcher; pin the CSR output dir.
process.env.RALPH_DASHBOARD_BROWSER_DIST = path.resolve(
  __dirname,
  '..',
  'dist',
  'ralph-dashboard',
  'browser',
);

// Then dynamically import and run the ESM server
(async () => {
  try {
    await import('../dist/ralph-dashboard/server/server.mjs');
  } catch (err) {
    console.error('Failed to start server:', err);
    process.exit(1);
  }
})();
