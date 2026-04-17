# Ralph Dashboard

Angular SSR app for browsing Ralph plan logs, artifacts, sessions, docs, and plan files in a workspace. Run it from the repository where Ralph is installed (the project root that contains `.ralph-workspace/`).

## Prerequisites

- **Node.js 22** (use [nvm](https://github.com/nvm-sh/nvm), for example `nvm install 22` and `nvm use v22`)
- **npm** (bundled with Node)

## Install

From this directory:

```bash
npm install
```

## Development

Use two terminals from `ralph-dashboard/`:

1. **Rebuild the app on change** (Angular client + server bundle):

   ```bash
   npm run watch
   ```

2. **Run the Node server with reload** (serves the last successful `dist/` build):

   ```bash
   npm run dev
   ```

Open the URL printed by the server (default port **8123**). Edit client or server code; `watch` rebuilds `dist/` and `dev` picks up changes to the server entry.

## Production

Build once, then start the server:

```bash
npm run build
npm start
```

The production server runs `dist/ralph-dashboard/server/server.mjs`.

### Port

Default port is **8123**. Override with the `PORT` environment variable:

```bash
PORT=8124 npm start
```

## Tests

- **All tests** (Jest API/server unit tests, then Vitest Angular tests):

  ```bash
  npm test
  ```

- **With coverage** (both Jest and Vitest coverage; project thresholds apply):

  ```bash
  npm run test:cov
  ```

## UI overview

The layout has a **workspace sidebar** and a **file tree** beside it:

- **Workspace roots:** Pick one of **Logs**, **Artifacts**, **Sessions**, **Docs**, or **Plans**. Each root maps to a directory under the workspace (see below).
- **File tree:** After a root is selected, the tree lists files and folders for that root. Expand directories to drill down; select a file to open it in the main area (markdown and other text in the file viewer; `.log` files in the log viewer with optional tailing).
- **Usage view:** Click the header Usage button or open `/usage` for a dedicated runtime/model token breakdown page with drill-down filters.

**Directories the dashboard reads** (relative to the workspace project root, i.e. the repo where Ralph runs):

| Root        | Path on disk                          |
|------------|----------------------------------------|
| Logs       | `.ralph-workspace/logs`                |
| Artifacts  | `.ralph-workspace/artifacts`           |
| Sessions   | `.ralph-workspace/sessions`            |
| Docs       | `docs`                                 |
| Plans      | Workspace root (repository root)     |

If a path does not exist yet, it may not appear in listings until it is created by Ralph or the project.
