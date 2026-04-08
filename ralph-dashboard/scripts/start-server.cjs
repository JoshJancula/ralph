// Load the CommonJS stub to set up Angular manifests
require('./angular-launch-server-stub.cjs');

// Then dynamically import and run the ESM server
(async () => {
  try {
    await import('../dist/ralph-dashboard/server/server.mjs');
  } catch (err) {
    console.error('Failed to start server:', err);
    process.exit(1);
  }
})();
