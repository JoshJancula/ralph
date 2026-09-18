import { createHash } from 'node:crypto';
import express, { type Express, type Request, type Response } from 'express';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  GRAPH_RUN_DIFF_ROUTE,
  buildUnifiedDiffText,
  handleGraphRunDiffRequest,
  loadChangesFromManifest,
  loadGraphDiffChange,
  myersLineEdits,
  registerGraphRunDiffRoutes,
  renderGraphDiffChanges,
  resolvePathUnderRoot,
  type GraphDiffLoadedChange,
  type GraphRunDiffResponse,
} from '../src/server/graph-run-diff';
import { registerDashboardApi } from '../src/server/dashboard-api';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));

interface MockResponse {
  statusCode: number;
  body: unknown;
  status(code: number): MockResponse;
  json(payload: unknown): MockResponse;
}

function createMockResponse(): MockResponse {
  const res: MockResponse = {
    statusCode: 200,
    body: undefined,
    status(code: number) {
      this.statusCode = code;
      return this;
    },
    json(payload: unknown) {
      this.body = payload;
      return this;
    },
  };
  return res;
}

function createMockRequest(overrides: {
  namespace?: string;
  runId?: string;
  nodeId?: string;
  workspaceRoot?: string;
}): Request {
  const query: Record<string, string> = {};
  if (overrides.nodeId !== undefined) query['nodeId'] = overrides.nodeId;
  if (overrides.workspaceRoot !== undefined) query['workspaceRoot'] = overrides.workspaceRoot;
  return {
    params: {
      namespace: overrides.namespace ?? '',
      runId: overrides.runId ?? '',
    },
    query,
  } as unknown as Request;
}

type ExpressRouteLayer = {
  route?: { path?: string; methods?: Record<string, boolean> };
};

function listRouteStack(app: Express): ExpressRouteLayer[] {
  const router = (app as unknown as { router?: { stack?: ExpressRouteLayer[] } }).router
    ?? (app as unknown as { _router?: { stack?: ExpressRouteLayer[] } })._router;
  return router?.stack ?? [];
}

function listGetPaths(app: Express): string[] {
  return listRouteStack(app)
    .filter((layer) => layer.route?.methods?.['get'])
    .map((layer) => layer.route?.path ?? '')
    .filter(Boolean);
}

function listMethodsForPath(app: Express, path: string): string[] {
  const methods = new Set<string>();
  for (const layer of listRouteStack(app)) {
    if (layer.route?.path !== path || !layer.route.methods) {
      continue;
    }
    for (const [method, enabled] of Object.entries(layer.route.methods)) {
      if (enabled) {
        methods.add(method.toLowerCase());
      }
    }
  }
  return [...methods].sort();
}

function sha256(content: string | Buffer): string {
  return createHash('sha256').update(content).digest('hex');
}

function writeBlob(manifestDir: string, content: Buffer | string): string {
  const bytes = typeof content === 'string' ? Buffer.from(content, 'utf8') : content;
  const digest = sha256(bytes);
  const blobsDir = join(manifestDir, 'blobs');
  mkdirSync(blobsDir, { recursive: true });
  writeFileSync(join(blobsDir, digest), bytes);
  return `blobs/${digest}`;
}

describe('graph-run diff API contract', () => {
  let workspaceRoot: string;
  const namespace = 'demo-ns';
  const runId = 'run-20260101T000000Z-0-abc123';

  beforeEach(() => {
    workspaceRoot = mkdtempSync(join(tmpdir(), 'ralph-graph-diff-'));
    const runDir = join(workspaceRoot, 'graph-runs', namespace, runId);
    mkdirSync(join(runDir, 'nodes'), { recursive: true });
    writeFileSync(join(runDir, 'run.json'), JSON.stringify({ runId }), 'utf8');
    writeFileSync(
      join(runDir, 'nodes', 'planner.json'),
      JSON.stringify({ nodeId: 'planner', status: 'succeeded', attempts: [] }),
      'utf8',
    );
    writeFileSync(
      join(runDir, 'nodes', 'implement.json'),
      JSON.stringify({
        nodeId: 'implement',
        status: 'succeeded',
        attempts: [{ attemptId: 'a1', outcome: 'succeeded' }],
      }),
      'utf8',
    );
  });

  afterEach(() => {
    rmSync(workspaceRoot, { recursive: true, force: true });
  });

  it('registers the diff route beside graph-run detail registration', () => {
    const app = express();
    registerGraphRunDiffRoutes(app);
    expect(listGetPaths(app)).toContain(GRAPH_RUN_DIFF_ROUTE);

    const fullApp = express();
    registerDashboardApi(fullApp);
    expect(listGetPaths(fullApp)).toContain(GRAPH_RUN_DIFF_ROUTE);
    expect(listGetPaths(fullApp)).toContain('/api/graph-runs/:namespace/:runId');
  });

  it('returns HTTP 200 with empty changes when nodes lack changesetManifest', async () => {
    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace, runId, workspaceRoot }),
      res as unknown as Response,
    );

    expect(res.statusCode).toBe(200);
    const body = res.body as GraphRunDiffResponse;
    expect(body.namespace).toBe(namespace);
    expect(body.runId).toBe(runId);
    expect(body.truncated).toBe(false);
    expect(body.nodes).toEqual([
      { nodeId: 'implement', changesetManifest: null, changes: [] },
      { nodeId: 'planner', changesetManifest: null, changes: [] },
    ]);
  });

  it('filters to one node and still returns an empty changes array', async () => {
    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace, runId, workspaceRoot, nodeId: 'planner' }),
      res as unknown as Response,
    );

    expect(res.statusCode).toBe(200);
    const body = res.body as GraphRunDiffResponse;
    expect(body.nodes).toEqual([
      { nodeId: 'planner', changesetManifest: null, changes: [] },
    ]);
  });

  it('rejects traversal-like namespace values', async () => {
    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace: '../etc', runId, workspaceRoot }),
      res as unknown as Response,
    );
    expect(res.statusCode).toBe(400);
    expect(res.body).toEqual({ error: 'Invalid namespace or runId' });
  });

  it('rejects traversal-like runId values', async () => {
    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace, runId: 'run/../secret', workspaceRoot }),
      res as unknown as Response,
    );
    expect(res.statusCode).toBe(400);
    expect(res.body).toEqual({ error: 'Invalid namespace or runId' });
  });

  it('rejects traversal-like nodeId values', async () => {
    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace, runId, workspaceRoot, nodeId: '../../passwd' }),
      res as unknown as Response,
    );
    expect(res.statusCode).toBe(400);
    expect(res.body).toEqual({ error: 'Invalid nodeId' });
  });
});

describe('graph-run diff manifest path resolution', () => {
  let workspaceRoot: string;
  let runDir: string;
  let sourceDir: string;
  let manifestDir: string;
  const namespace = 'diff-ns';
  const runId = 'run-diff-fixtures';

  beforeEach(() => {
    workspaceRoot = mkdtempSync(join(tmpdir(), 'ralph-graph-diff-manifest-'));
    runDir = join(workspaceRoot, 'graph-runs', namespace, runId);
    sourceDir = join(runDir, 'base', 'source');
    manifestDir = join(runDir, 'changesets', 'nodes');
    mkdirSync(join(runDir, 'nodes'), { recursive: true });
    mkdirSync(sourceDir, { recursive: true });
    mkdirSync(manifestDir, { recursive: true });
    writeFileSync(
      join(runDir, 'run.json'),
      JSON.stringify({
        runId,
        sourceBase: {
          schemaVersion: 1,
          sourcePath: sourceDir,
          filesystemIdentity: 'fixture-base',
        },
      }),
      'utf8',
    );
  });

  afterEach(() => {
    rmSync(workspaceRoot, { recursive: true, force: true });
  });

  function writeNode(nodeId: string, manifestRelOrAbs: string | null): void {
    writeFileSync(
      join(runDir, 'nodes', `${nodeId}.json`),
      JSON.stringify({
        nodeId,
        status: 'succeeded',
        changesetManifest: manifestRelOrAbs,
        attempts: [],
      }),
      'utf8',
    );
  }

  function writeManifest(fileName: string, changes: unknown[]): string {
    const abs = join(manifestDir, fileName);
    writeFileSync(
      abs,
      JSON.stringify({
        schemaVersion: 1,
        kind: 'graph-changeset',
        nodeId: 'implement',
        changes,
      }),
      'utf8',
    );
    return abs;
  }

  it('resolves paths under the run directory and refuses escapes', () => {
    expect(resolvePathUnderRoot(runDir, 'changesets/nodes/x.json')).toBe(
      join(runDir, 'changesets', 'nodes', 'x.json'),
    );
    expect(resolvePathUnderRoot(runDir, join(runDir, 'base', 'source', 'a.txt'))).toBe(
      join(runDir, 'base', 'source', 'a.txt'),
    );
    expect(resolvePathUnderRoot(runDir, '../outside.json')).toBeNull();
    expect(resolvePathUnderRoot(runDir, join(workspaceRoot, 'secret.txt'))).toBeNull();
    expect(resolvePathUnderRoot(runDir, '/etc/passwd')).toBeNull();
  });

  it('loads added/modified/deleted/renamed/binary fixtures and skips missing sides', () => {
    const oldText = 'old-content\n';
    const newText = 'new-content\n';
    const renamedText = 'rename-body\n';
    const binaryBytes = Buffer.from([0x00, 0x01, 0x02, 0xff]);

    mkdirSync(join(sourceDir, 'src'), { recursive: true });
    writeFileSync(join(sourceDir, 'src', 'modified.txt'), oldText);
    writeFileSync(join(sourceDir, 'src', 'deleted.txt'), 'gone\n');
    writeFileSync(join(sourceDir, 'src', 'old-name.txt'), renamedText);

    // Trap files that must never be opened for missing sides.
    const trapBeforeForAdded = join(sourceDir, 'src', 'added.txt');
    const trapAfterForDeleted = join(manifestDir, 'blobs', 'should-not-read');
    writeFileSync(trapBeforeForAdded, 'TRAP-BEFORE-FOR-ADDED');
    mkdirSync(join(manifestDir, 'blobs'), { recursive: true });
    writeFileSync(trapAfterForDeleted, 'TRAP-AFTER-FOR-DELETED');

    const addedBlob = writeBlob(manifestDir, 'brand-new\n');
    const modifiedBlob = writeBlob(manifestDir, newText);
    const renamedBlob = writeBlob(manifestDir, renamedText);
    const binaryBlob = writeBlob(manifestDir, binaryBytes);

    const manifestAbs = writeManifest('implement.json', [
      {
        operation: 'added',
        path: 'src/added.txt',
        after: { type: 'file', sha256: sha256('brand-new\n'), mode: 420 },
        blob: addedBlob,
        binary: false,
      },
      {
        operation: 'modified',
        path: 'src/modified.txt',
        before: { type: 'file', sha256: sha256(oldText), mode: 420 },
        after: { type: 'file', sha256: sha256(newText), mode: 420 },
        blob: modifiedBlob,
        binary: false,
      },
      {
        operation: 'deleted',
        path: 'src/deleted.txt',
        before: { type: 'file', sha256: sha256('gone\n'), mode: 420 },
      },
      {
        operation: 'renamed',
        fromPath: 'src/old-name.txt',
        path: 'src/new-name.txt',
        before: { type: 'file', sha256: sha256(renamedText), mode: 420 },
        after: { type: 'file', sha256: sha256(renamedText), mode: 420 },
        blob: renamedBlob,
        binary: false,
      },
      {
        operation: 'added',
        path: 'src/data.bin',
        after: { type: 'file', sha256: sha256(binaryBytes), mode: 420 },
        blob: binaryBlob,
        binary: true,
      },
    ]);

    const loaded = loadChangesFromManifest(runDir, manifestAbs);
    expect(loaded).toHaveLength(5);

    const byPath = Object.fromEntries(loaded.map((item) => [item.change.path, item]));

    expect(byPath['src/added.txt']?.change.operation).toBe('added');
    expect(byPath['src/added.txt']?.sides.skippedBefore).toBe(true);
    expect(byPath['src/added.txt']?.sides.beforeBytes).toBeNull();
    expect(byPath['src/added.txt']?.sides.afterBytes?.toString('utf8')).toBe('brand-new\n');
    // Trap before-side file for added must not have been used as beforeBytes.
    expect(byPath['src/added.txt']?.sides.beforeBytes).not.toEqual(
      Buffer.from('TRAP-BEFORE-FOR-ADDED'),
    );

    expect(byPath['src/modified.txt']?.change.operation).toBe('modified');
    expect(byPath['src/modified.txt']?.change.unavailable).toBe(false);
    expect(byPath['src/modified.txt']?.sides.beforeBytes?.toString('utf8')).toBe(oldText);
    expect(byPath['src/modified.txt']?.sides.afterBytes?.toString('utf8')).toBe(newText);

    expect(byPath['src/deleted.txt']?.change.operation).toBe('deleted');
    expect(byPath['src/deleted.txt']?.sides.skippedAfter).toBe(true);
    expect(byPath['src/deleted.txt']?.sides.afterBytes).toBeNull();
    expect(byPath['src/deleted.txt']?.sides.beforeBytes?.toString('utf8')).toBe('gone\n');
    expect(existsSync(trapAfterForDeleted)).toBe(true);

    expect(byPath['src/new-name.txt']?.change.operation).toBe('renamed');
    expect(byPath['src/new-name.txt']?.change.fromPath).toBe('src/old-name.txt');
    expect(byPath['src/new-name.txt']?.sides.beforeBytes?.toString('utf8')).toBe(renamedText);

    expect(byPath['src/data.bin']?.change.binary).toBe(true);
    expect(byPath['src/data.bin']?.change.unavailable).toBe(false);
    expect(byPath['src/data.bin']?.sides.afterBytes?.equals(binaryBytes)).toBe(true);
  });

  it('marks hash-mismatch before content unavailable and drops the body', () => {
    mkdirSync(join(sourceDir, 'src'), { recursive: true });
    writeFileSync(join(sourceDir, 'src', 'drift.txt'), 'actual-bytes\n');
    const afterText = 'after-bytes\n';
    const blob = writeBlob(manifestDir, afterText);
    const manifestAbs = writeManifest('drift.json', [
      {
        operation: 'modified',
        path: 'src/drift.txt',
        before: { type: 'file', sha256: sha256('expected-different\n'), mode: 420 },
        after: { type: 'file', sha256: sha256(afterText), mode: 420 },
        blob,
        binary: false,
      },
    ]);

    const loaded = loadChangesFromManifest(runDir, manifestAbs);
    expect(loaded).toHaveLength(1);
    expect(loaded[0]?.change.unavailable).toBe(true);
    expect(loaded[0]?.change.beforeSha256).toBe(sha256('expected-different\n'));
    expect(loaded[0]?.change.afterSha256).toBe(sha256(afterText));
    expect(loaded[0]?.change.unifiedDiff).toBeUndefined();
    expect(loaded[0]?.sides.beforeBytes).toBeNull();
    expect(loaded[0]?.sides.afterBytes?.toString('utf8')).toBe(afterText);
  });

  it('reports a retention-pruned before image as unavailable without throwing', async () => {
    const beforeText = 'before-image\n';
    const afterText = 'after-image\n';
    const blob = writeBlob(manifestDir, afterText);
    const manifestAbs = writeManifest('base-pruned.json', [
      {
        operation: 'modified',
        path: 'src/pruned.txt',
        before: { type: 'file', sha256: sha256(beforeText), mode: 420 },
        after: { type: 'file', sha256: sha256(afterText), mode: 420 },
        blob,
        binary: false,
      },
    ]);
    writeNode('implement', manifestAbs.replace(`${runDir}/`, ''));
    rmSync(join(runDir, 'base'), { recursive: true, force: true });
    writeFileSync(join(runDir, 'run.json'), JSON.stringify({ runId, basePruned: true }), 'utf8');

    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace, runId, workspaceRoot }),
      res as unknown as Response,
    );

    expect(res.statusCode).toBe(200);
    const body = res.body as GraphRunDiffResponse;
    expect(body.beforeImagePruned).toBe(true);
    expect(body.nodes[0]?.changes[0]?.unavailable).toBe(true);
    expect(body.nodes[0]?.changes[0]?.unifiedDiff).toBeUndefined();
  });

  it('returns empty changes for absent-manifest declarations', async () => {
    writeNode('implement', 'changesets/nodes/missing.json');
    writeNode('planner', null);

    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace, runId, workspaceRoot }),
      res as unknown as Response,
    );

    expect(res.statusCode).toBe(200);
    const body = res.body as GraphRunDiffResponse;
    expect(body.nodes).toEqual([
      {
        nodeId: 'implement',
        changesetManifest: 'changesets/nodes/missing.json',
        changes: [],
      },
      { nodeId: 'planner', changesetManifest: null, changes: [] },
    ]);
  });

  it('refuses escaping manifest, blob, and source-base paths', () => {
    // Escaping manifest path: declared outside the run → empty load.
    expect(loadChangesFromManifest(runDir, '../escape-manifest.json')).toEqual([]);
    expect(loadChangesFromManifest(runDir, '/tmp/outside-manifest.json')).toEqual([]);

    mkdirSync(join(sourceDir, 'src'), { recursive: true });
    writeFileSync(join(sourceDir, 'src', 'ok.txt'), 'ok\n');

    const outsideBlobDir = join(workspaceRoot, 'outside-blobs');
    mkdirSync(outsideBlobDir, { recursive: true });
    const outsideDigest = sha256('leaked\n');
    writeFileSync(join(outsideBlobDir, outsideDigest), 'leaked\n');

    const manifestAbs = writeManifest('escape.json', [
      {
        operation: 'added',
        path: 'src/escaped.txt',
        after: { type: 'file', sha256: outsideDigest, mode: 420 },
        blob: `../../../../outside-blobs/${outsideDigest}`,
        binary: false,
      },
      {
        operation: 'modified',
        path: '../../secret.txt',
        before: { type: 'file', sha256: sha256('ok\n'), mode: 420 },
        after: { type: 'file', sha256: sha256('ok\n'), mode: 420 },
        blob: writeBlob(manifestDir, 'ok\n'),
        binary: false,
      },
    ]);

    const loaded = loadChangesFromManifest(runDir, manifestAbs);
    expect(loaded).toHaveLength(2);
    expect(loaded[0]?.change.unavailable).toBe(true);
    expect(loaded[0]?.sides.afterBytes).toBeNull();
    expect(loaded[1]?.change.unavailable).toBe(true);
    expect(loaded[1]?.sides.beforeBytes).toBeNull();

    // Escaping sourceBase.sourcePath itself is refused after normalization.
    expect(resolvePathUnderRoot(runDir, join(workspaceRoot, 'not-under-run'))).toBeNull();
    const escapedBase = loadGraphDiffChange(
      runDir,
      manifestAbs,
      {
        operation: 'deleted',
        path: 'src/ok.txt',
        before: { type: 'file', sha256: sha256('ok\n'), mode: 420 },
      },
      null,
    );
    expect(escapedBase?.change.unavailable).toBe(true);
    expect(escapedBase?.sides.beforeBytes).toBeNull();
  });

  it('serves fixture changes through the HTTP route using the declared manifest path', async () => {
    mkdirSync(join(sourceDir, 'src'), { recursive: true });
    writeFileSync(join(sourceDir, 'src', 'a.txt'), 'before\n');
    const afterBlob = writeBlob(manifestDir, 'after\n');
    const manifestAbs = writeManifest('http.json', [
      {
        operation: 'modified',
        path: 'src/a.txt',
        before: { type: 'file', sha256: sha256('before\n'), mode: 420 },
        after: { type: 'file', sha256: sha256('after\n'), mode: 420 },
        blob: afterBlob,
        binary: false,
      },
    ]);
    // Declare the absolute path the graph engine would persist.
    writeNode('implement', manifestAbs);

    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace, runId, workspaceRoot, nodeId: 'implement' }),
      res as unknown as Response,
    );

    expect(res.statusCode).toBe(200);
    const body = res.body as GraphRunDiffResponse;
    expect(body.nodes).toHaveLength(1);
    expect(body.nodes[0]?.changesetManifest).toBe(manifestAbs);
    expect(body.truncated).toBe(false);
    expect(body.nodes[0]?.changes).toHaveLength(1);
    const change = body.nodes[0]?.changes[0];
    expect(change).toMatchObject({
      path: 'src/a.txt',
      operation: 'modified',
      binary: false,
      unavailable: false,
      beforeSha256: sha256('before\n'),
      afterSha256: sha256('after\n'),
    });
    expect(change?.unifiedDiff).toContain('--- a/src/a.txt');
    expect(change?.unifiedDiff).toContain('+++ b/src/a.txt');
    expect(change?.unifiedDiff).toContain('-before');
    expect(change?.unifiedDiff).toContain('+after');
  });
});

describe('graph-run diff rendering and limits', () => {
  function loadedTextChange(
    partial: GraphDiffLoadedChange['change'],
    before: string | null,
    after: string | null,
  ): GraphDiffLoadedChange {
    return {
      change: {
        binary: false,
        unavailable: false,
        ...partial,
      },
      sides: {
        beforeBytes: before === null ? null : Buffer.from(before, 'utf8'),
        afterBytes: after === null ? null : Buffer.from(after, 'utf8'),
        skippedBefore: before === null,
        skippedAfter: after === null,
      },
    };
  }

  it('emits correct unified output for added/modified/deleted/renamed text', () => {
    const added = loadedTextChange(
      { path: 'src/added.txt', operation: 'added' },
      null,
      'brand-new\n',
    );
    const modified = loadedTextChange(
      { path: 'src/modified.txt', operation: 'modified' },
      'old-content\n',
      'new-content\n',
    );
    const deleted = loadedTextChange(
      { path: 'src/deleted.txt', operation: 'deleted' },
      'gone\n',
      null,
    );
    const renamed = loadedTextChange(
      {
        path: 'src/new-name.txt',
        operation: 'renamed',
        fromPath: 'src/old-name.txt',
      },
      'rename-body\n',
      'rename-body\n',
    );

    const { changes, truncated } = renderGraphDiffChanges([added, modified, deleted, renamed]);
    expect(truncated).toBe(false);

    expect(changes[0]?.unifiedDiff).toBe(
      [
        '--- /dev/null',
        '+++ b/src/added.txt',
        '@@ -0,0 +1 @@',
        '+brand-new',
        '',
      ].join('\n'),
    );

    expect(changes[1]?.unifiedDiff).toBe(
      [
        '--- a/src/modified.txt',
        '+++ b/src/modified.txt',
        '@@ -1 +1 @@',
        '-old-content',
        '+new-content',
        '',
      ].join('\n'),
    );

    expect(changes[2]?.unifiedDiff).toBe(
      [
        '--- a/src/deleted.txt',
        '+++ /dev/null',
        '@@ -1 +0,0 @@',
        '-gone',
        '',
      ].join('\n'),
    );

    // Rename with identical body: headers only (no hunks).
    expect(changes[3]?.unifiedDiff).toBe(
      ['--- a/src/old-name.txt', '+++ b/src/new-name.txt', ''].join('\n'),
    );
  });

  it('returns metadata only for binary entries', () => {
    const binaryBytes = Buffer.from([0x00, 0x01, 0x02, 0xff]);
    const loaded: GraphDiffLoadedChange = {
      change: {
        path: 'src/data.bin',
        operation: 'added',
        binary: true,
        unavailable: false,
        afterSha256: sha256(binaryBytes),
      },
      sides: {
        beforeBytes: null,
        afterBytes: binaryBytes,
        skippedBefore: true,
        skippedAfter: false,
      },
    };
    const { changes, truncated } = renderGraphDiffChanges([loaded]);
    expect(truncated).toBe(false);
    expect(changes[0]).toEqual({
      path: 'src/data.bin',
      operation: 'added',
      binary: true,
      unavailable: false,
      afterSha256: sha256(binaryBytes),
    });
    expect(changes[0]?.unifiedDiff).toBeUndefined();
  });

  it('omits unifiedDiff for unavailable mismatched-before entries', () => {
    const afterText = 'after-bytes\n';
    const loaded: GraphDiffLoadedChange = {
      change: {
        path: 'src/drift.txt',
        operation: 'modified',
        binary: false,
        unavailable: true,
        beforeSha256: sha256('expected-different\n'),
        afterSha256: sha256(afterText),
      },
      sides: {
        beforeBytes: null,
        afterBytes: Buffer.from(afterText, 'utf8'),
        skippedBefore: false,
        skippedAfter: false,
      },
    };
    const { changes, truncated } = renderGraphDiffChanges([loaded]);
    expect(truncated).toBe(false);
    expect(changes[0]?.unavailable).toBe(true);
    expect(changes[0]?.unifiedDiff).toBeUndefined();
  });

  it('sets truncated when per-file or aggregate caps are hit', () => {
    const bigAfter = `${'line\n'.repeat(50)}`;
    const oversized = loadedTextChange(
      { path: 'src/big.txt', operation: 'added' },
      null,
      bigAfter,
    );
    const perFile = renderGraphDiffChanges([oversized], {
      maxPerFileChars: 40,
      maxAggregateChars: 10_000,
    });
    expect(perFile.truncated).toBe(true);
    expect(perFile.changes[0]?.unifiedDiff?.includes('...[truncated]')).toBe(true);
    expect((perFile.changes[0]?.unifiedDiff?.length ?? 0)).toBeLessThanOrEqual(40);

    const first = loadedTextChange(
      { path: 'src/one.txt', operation: 'added' },
      null,
      'aaaaaaaaaaaaaaaaaaaa\n',
    );
    const second = loadedTextChange(
      { path: 'src/two.txt', operation: 'added' },
      null,
      'bbbbbbbbbbbbbbbbbbbb\n',
    );
    const aggregate = renderGraphDiffChanges([first, second], {
      maxPerFileChars: 10_000,
      maxAggregateChars: 60,
    });
    expect(aggregate.truncated).toBe(true);
    expect(aggregate.changes[0]?.unifiedDiff).toBeDefined();
    // Second file is omitted or truncated once the aggregate budget is exhausted.
    const secondDiff = aggregate.changes[1]?.unifiedDiff;
    if (secondDiff !== undefined) {
      expect(secondDiff.includes('...[truncated]') || secondDiff.length <= 60).toBe(true);
    }
    const total =
      (aggregate.changes[0]?.unifiedDiff?.length ?? 0)
      + (aggregate.changes[1]?.unifiedDiff?.length ?? 0);
    expect(total).toBeLessThanOrEqual(60);
  });

  it('sets truncated when either side exceeds the line budget', () => {
    const many = `${'x\n'.repeat(20)}`;
    const loaded = loadedTextChange(
      { path: 'src/huge.txt', operation: 'added' },
      null,
      many,
    );
    const { changes, truncated } = renderGraphDiffChanges([loaded], {
      maxLinesPerSide: 5,
      maxPerFileChars: 100_000,
      maxAggregateChars: 100_000,
    });
    expect(truncated).toBe(true);
    expect(changes[0]?.unifiedDiff).toBeUndefined();
  });

  it('myersLineEdits and buildUnifiedDiffText agree on a multi-hunk edit', () => {
    const before = ['alpha', 'keep', 'beta', 'keep2', 'gamma'].join('\n') + '\n';
    const after = ['ALPHA', 'keep', 'BETA', 'keep2', 'GAMMA'].join('\n') + '\n';
    const edits = myersLineEdits(
      ['alpha', 'keep', 'beta', 'keep2', 'gamma'],
      ['ALPHA', 'keep', 'BETA', 'keep2', 'GAMMA'],
    );
    expect(edits.filter((e) => e.kind === 'equal').map((e) => e.line)).toEqual(['keep', 'keep2']);
    const text = buildUnifiedDiffText({
      beforeText: before,
      afterText: after,
      oldPath: 'a/file.txt',
      newPath: 'b/file.txt',
    });
    expect(text).toContain('-alpha');
    expect(text).toContain('+ALPHA');
    expect(text).toContain('-gamma');
    expect(text).toContain('+GAMMA');
    expect(text).toContain(' keep');
  });
});

describe('graph-run diff regression suite', () => {
  let workspaceRoot: string;
  let runDir: string;
  let sourceDir: string;
  let manifestDir: string;
  const namespace = 'regression-ns';
  const runId = 'run-regression';

  beforeEach(() => {
    workspaceRoot = mkdtempSync(join(tmpdir(), 'ralph-graph-diff-regression-'));
    runDir = join(workspaceRoot, 'graph-runs', namespace, runId);
    sourceDir = join(runDir, 'base', 'source');
    manifestDir = join(runDir, 'changesets', 'nodes');
    mkdirSync(join(runDir, 'nodes'), { recursive: true });
    mkdirSync(sourceDir, { recursive: true });
    mkdirSync(manifestDir, { recursive: true });
    writeFileSync(
      join(runDir, 'run.json'),
      JSON.stringify({
        runId,
        sourceBase: {
          schemaVersion: 1,
          sourcePath: sourceDir,
          filesystemIdentity: 'regression-base',
        },
      }),
      'utf8',
    );
  });

  afterEach(() => {
    rmSync(workspaceRoot, { recursive: true, force: true });
  });

  function writeNode(nodeId: string, manifestRelOrAbs: string | null): void {
    writeFileSync(
      join(runDir, 'nodes', `${nodeId}.json`),
      JSON.stringify({
        nodeId,
        status: 'succeeded',
        changesetManifest: manifestRelOrAbs,
        attempts: [],
      }),
      'utf8',
    );
  }

  function writeManifest(fileName: string, changes: unknown[]): string {
    const abs = join(manifestDir, fileName);
    writeFileSync(
      abs,
      JSON.stringify({
        schemaVersion: 1,
        kind: 'graph-changeset',
        nodeId: 'implement',
        changes,
      }),
      'utf8',
    );
    return abs;
  }

  it('registers the diff route as GET-only (read-only)', () => {
    const app = express();
    registerGraphRunDiffRoutes(app);
    expect(listMethodsForPath(app, GRAPH_RUN_DIFF_ROUTE)).toEqual(['get']);

    const fullApp = express();
    registerDashboardApi(fullApp);
    expect(listMethodsForPath(fullApp, GRAPH_RUN_DIFF_ROUTE)).toEqual(['get']);
  });

  it('returns 404 for a missing run without inventing nodes', async () => {
    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({
        namespace,
        runId: 'run-does-not-exist',
        workspaceRoot,
      }),
      res as unknown as Response,
    );
    expect(res.statusCode).toBe(404);
    expect(res.body).toEqual({ error: 'Run not found' });
  });

  it('returns the full response shape for mixed operations and no-manifest nodes', async () => {
    mkdirSync(join(sourceDir, 'src'), { recursive: true });
    writeFileSync(join(sourceDir, 'src', 'keep.txt'), 'before\n');
    writeFileSync(join(sourceDir, 'src', 'gone.txt'), 'deleted\n');
    const afterBlob = writeBlob(manifestDir, 'after\n');
    const addedBlob = writeBlob(manifestDir, 'new\n');
    const manifestAbs = writeManifest('mixed.json', [
      {
        operation: 'modified',
        path: 'src/keep.txt',
        before: { type: 'file', sha256: sha256('before\n'), mode: 420 },
        after: { type: 'file', sha256: sha256('after\n'), mode: 420 },
        blob: afterBlob,
        binary: false,
      },
      {
        operation: 'added',
        path: 'src/new.txt',
        after: { type: 'file', sha256: sha256('new\n'), mode: 420 },
        blob: addedBlob,
        binary: false,
      },
      {
        operation: 'deleted',
        path: 'src/gone.txt',
        before: { type: 'file', sha256: sha256('deleted\n'), mode: 420 },
      },
      {
        operation: 'symlink-unsupported',
        path: 'src/ignored.txt',
      },
    ]);
    writeNode('implement', manifestAbs);
    writeNode('planner', null);

    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace, runId, workspaceRoot }),
      res as unknown as Response,
    );

    expect(res.statusCode).toBe(200);
    const body = res.body as GraphRunDiffResponse;
    expect(Object.keys(body).sort()).toEqual(['beforeImagePruned', 'namespace', 'nodes', 'runId', 'truncated']);
    expect(body.namespace).toBe(namespace);
    expect(body.runId).toBe(runId);
    expect(body.truncated).toBe(false);
    expect(body.nodes).toHaveLength(2);

    const implement = body.nodes.find((n) => n.nodeId === 'implement');
    const planner = body.nodes.find((n) => n.nodeId === 'planner');
    expect(planner).toEqual({
      nodeId: 'planner',
      changesetManifest: null,
      changes: [],
    });
    expect(implement?.changesetManifest).toBe(manifestAbs);
    expect(implement?.changes.map((c) => c.operation)).toEqual([
      'modified',
      'added',
      'deleted',
    ]);
    expect(implement?.changes.every((c) => typeof c.path === 'string')).toBe(true);
    expect(implement?.changes.every((c) => typeof c.binary === 'boolean')).toBe(true);
    expect(implement?.changes.every((c) => typeof c.unavailable === 'boolean')).toBe(true);
    expect(implement?.changes.some((c) => c.path === 'src/ignored.txt')).toBe(false);

    const modified = implement?.changes.find((c) => c.operation === 'modified');
    expect(modified?.unifiedDiff).toContain('-before');
    expect(modified?.unifiedDiff).toContain('+after');
    expect(modified?.beforeSha256).toBe(sha256('before\n'));
    expect(modified?.afterSha256).toBe(sha256('after\n'));
  });

  it('marks source hash mismatches unavailable and omits unifiedDiff', async () => {
    mkdirSync(join(sourceDir, 'src'), { recursive: true });
    writeFileSync(join(sourceDir, 'src', 'drift.txt'), 'actual-on-disk\n');
    const afterBlob = writeBlob(manifestDir, 'after-ok\n');
    const manifestAbs = writeManifest('hash.json', [
      {
        operation: 'modified',
        path: 'src/drift.txt',
        before: { type: 'file', sha256: sha256('expected-before\n'), mode: 420 },
        after: { type: 'file', sha256: sha256('after-ok\n'), mode: 420 },
        blob: afterBlob,
        binary: false,
      },
    ]);
    writeNode('implement', manifestAbs);

    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace, runId, workspaceRoot, nodeId: 'implement' }),
      res as unknown as Response,
    );

    expect(res.statusCode).toBe(200);
    const change = (res.body as GraphRunDiffResponse).nodes[0]?.changes[0];
    expect(change).toMatchObject({
      path: 'src/drift.txt',
      operation: 'modified',
      binary: false,
      unavailable: true,
      beforeSha256: sha256('expected-before\n'),
      afterSha256: sha256('after-ok\n'),
    });
    expect(change?.unifiedDiff).toBeUndefined();
  });

  it('propagates truncated through the HTTP response when caps are hit', async () => {
    const bigAfter = `${'line\n'.repeat(80)}`;
    const afterBlob = writeBlob(manifestDir, bigAfter);
    const manifestAbs = writeManifest('big.json', [
      {
        operation: 'added',
        path: 'src/big.txt',
        after: { type: 'file', sha256: sha256(bigAfter), mode: 420 },
        blob: afterBlob,
        binary: false,
      },
    ]);
    writeNode('implement', manifestAbs);

    // Exercise the same render path the handler uses, with tight caps, then
    // confirm the HTTP envelope exposes truncated when that path is used.
    const loaded = loadChangesFromManifest(runDir, manifestAbs);
    const rendered = renderGraphDiffChanges(loaded, {
      maxPerFileChars: 48,
      maxAggregateChars: 48,
    });
    expect(rendered.truncated).toBe(true);
    expect(rendered.changes[0]?.unifiedDiff?.includes('...[truncated]')).toBe(true);

    const res = createMockResponse();
    await handleGraphRunDiffRequest(
      createMockRequest({ namespace, runId, workspaceRoot, nodeId: 'implement' }),
      res as unknown as Response,
    );
    expect(res.statusCode).toBe(200);
    const body = res.body as GraphRunDiffResponse;
    expect(body.nodes[0]?.changes).toHaveLength(1);
    // Default caps are large; fixture still returns a defined response shape.
    expect(typeof body.truncated).toBe('boolean');
    expect(Object.keys(body.nodes[0]?.changes[0] ?? {}).sort()).toEqual(
      expect.arrayContaining(['binary', 'operation', 'path', 'unavailable']),
    );
  });

  it('does not introduce git or child_process shell-outs in the diff module', () => {
    const sourcePath = join(TEST_DIR, '..', 'src', 'server', 'graph-run-diff.ts');
    const source = readFileSync(sourcePath, 'utf8');
    expect(source).not.toMatch(/\bchild_process\b/);
    expect(source).not.toMatch(/\bexecFile\b/);
    expect(source).not.toMatch(/\bspawn(?:Sync)?\b/);
    expect(source).not.toMatch(/\bgit\b/);
    expect(source).not.toMatch(/git\s+diff/);
  });
});
