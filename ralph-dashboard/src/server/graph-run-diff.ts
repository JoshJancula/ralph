import type { Express, Request, Response } from 'express';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync, promises as fs } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { findDashboardRoots } from '../paths';
import { graphRunPath } from './state-paths';

/** Path segment / id charset shared with graph-run detail routes. */
const GRAPH_RUN_SEGMENT_RE = /^[A-Za-z0-9._-]+$/;

export type GraphDiffOperation = 'added' | 'modified' | 'deleted' | 'renamed';

/**
 * One file-level change for a graph node. Safe text entries may include
 * `unifiedDiff`; binary and unavailable entries expose metadata only.
 */
export interface GraphDiffChange {
  path: string;
  operation: GraphDiffOperation;
  fromPath?: string;
  binary: boolean;
  /** True when before content cannot be verified or read. */
  unavailable: boolean;
  /** Unified diff text; omitted for binary or unavailable entries. */
  unifiedDiff?: string;
  beforeSha256?: string;
  afterSha256?: string;
}

export interface GraphDiffNodeResult {
  nodeId: string;
  /** Declared manifest path when present; null when the node has none. */
  changesetManifest: string | null;
  changes: GraphDiffChange[];
}

export interface GraphRunDiffResponse {
  namespace: string;
  runId: string;
  /** The retained source before-image was removed by graph base retention. */
  beforeImagePruned: boolean;
  nodes: GraphDiffNodeResult[];
  /** True when a per-file or aggregate render cap was hit. */
  truncated: boolean;
}

/** Default per-file unified-diff character budget (UTF-16 code units). */
export const GRAPH_DIFF_MAX_PER_FILE_CHARS = 64 * 1024;
/** Default aggregate unified-diff character budget across the response. */
export const GRAPH_DIFF_MAX_AGGREGATE_CHARS = 256 * 1024;
/** Skip full LCS when either side exceeds this many lines; mark truncated. */
export const GRAPH_DIFF_MAX_LINES_PER_SIDE = 4000;

export interface GraphDiffRenderLimits {
  maxPerFileChars?: number;
  maxAggregateChars?: number;
  maxLinesPerSide?: number;
}

type DiffEdit =
  | { kind: 'equal'; line: string }
  | { kind: 'insert'; line: string }
  | { kind: 'delete'; line: string };

/** Loaded file sides used by later rendering; never returned over the wire. */
export interface GraphDiffLoadedSides {
  /** Before bytes when the operation has a before side and the read succeeded. */
  beforeBytes: Buffer | null;
  /** After bytes when the operation has an after blob and the read succeeded. */
  afterBytes: Buffer | null;
  /** True when a before side was not required (added). */
  skippedBefore: boolean;
  /** True when an after side was not required (deleted) or has no blob. */
  skippedAfter: boolean;
}

export interface GraphDiffLoadedChange {
  change: GraphDiffChange;
  sides: GraphDiffLoadedSides;
}

export function isValidGraphRunSegment(value: string): boolean {
  return value.length > 0 && GRAPH_RUN_SEGMENT_RE.test(value);
}

/**
 * Resolve `candidate` so the normalized absolute path stays strictly inside
 * `root`. Absolute candidates are accepted only when they already live under
 * root. Relative candidates are joined onto root. Escapes (including `..`
 * after normalization) return null — the caller must not read the path.
 *
 * Existing path prefixes are compared via realpath so macOS `/var` vs
 * `/private/var` (and similar symlink roots) still count as containment. The
 * returned path is the resolved absolute candidate (not necessarily realpath'd)
 * so callers keep the path form they passed when it was already absolute.
 */
export function resolvePathUnderRoot(root: string, candidate: string): string | null {
  if (!candidate || typeof candidate !== 'string') {
    return null;
  }
  if (candidate.includes('\0')) {
    return null;
  }
  const rootResolved = resolve(root);
  const absolute = isAbsolute(candidate)
    ? resolve(candidate)
    : resolve(rootResolved, candidate);

  const realExistingPrefix = (path: string): string => {
    try {
      if (existsSync(path)) {
        return realpathSync(path);
      }
    } catch {
      // Fall through and walk parents.
    }
    let parent = dirname(path);
    const parts: string[] = [];
    let cursor = path;
    while (parent !== cursor) {
      parts.unshift(cursor.slice(parent.length + 1) || '');
      try {
        if (existsSync(parent)) {
          return parts.reduce((acc, part) => (part ? join(acc, part) : acc), realpathSync(parent));
        }
      } catch {
        // keep walking
      }
      cursor = parent;
      parent = dirname(parent);
    }
    return path;
  };

  const rootCmp = realExistingPrefix(rootResolved);
  const absCmp = realExistingPrefix(absolute);
  const rel = relative(rootCmp, absCmp);
  if (!rel || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    return null;
  }
  return absolute;
}

function resolveGraphRunDir(workspaceRootQuery: string, namespace: string, runId: string): string {
  const { workspaceRoot } = findDashboardRoots();
  const effective = workspaceRootQuery ? resolve(workspaceRootQuery) : workspaceRoot;
  return graphRunPath(effective, namespace, runId);
}

function safeReadJson(filePath: string): Record<string, unknown> {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8')) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function isJsonRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function sha256Hex(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

function asOperation(value: unknown): GraphDiffOperation | null {
  if (value === 'added' || value === 'modified' || value === 'deleted' || value === 'renamed') {
    return value;
  }
  return null;
}

/**
 * Split text into lines without trailing newline markers. An empty string
 * yields no lines. A final empty segment from a trailing `\n` is dropped so
 * `"a\n"` is one line `"a"`.
 */
export function splitTextLines(text: string): { lines: string[]; newlineAtEof: boolean } {
  if (text.length === 0) {
    return { lines: [], newlineAtEof: false };
  }
  const newlineAtEof = text.endsWith('\n');
  const raw = text.split('\n');
  if (newlineAtEof) {
    raw.pop();
  }
  return { lines: raw, newlineAtEof };
}

/**
 * Line-level shortest edit script via LCS dynamic programming.
 * Dependency-free; callers must cap side length (see GRAPH_DIFF_MAX_LINES_PER_SIDE).
 */
export function myersLineEdits(a: string[], b: string[]): DiffEdit[] {
  const n = a.length;
  const m = b.length;
  if (n === 0 && m === 0) {
    return [];
  }
  if (n === 0) {
    return b.map((line) => ({ kind: 'insert' as const, line }));
  }
  if (m === 0) {
    return a.map((line) => ({ kind: 'delete' as const, line }));
  }

  // Row-major Uint16 LCS lengths; values never exceed n+m and fit uint16 for capped sides.
  const cols = m + 1;
  const dp = new Uint16Array((n + 1) * cols);
  for (let i = 1; i <= n; i += 1) {
    const row = i * cols;
    const prevRow = (i - 1) * cols;
    for (let j = 1; j <= m; j += 1) {
      if (a[i - 1] === b[j - 1]) {
        dp[row + j] = dp[prevRow + j - 1]! + 1;
      } else {
        const up = dp[prevRow + j]!;
        const left = dp[row + j - 1]!;
        dp[row + j] = up >= left ? up : left;
      }
    }
  }

  const edits: DiffEdit[] = [];
  let i = n;
  let j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && a[i - 1] === b[j - 1]) {
      edits.push({ kind: 'equal', line: a[i - 1]! });
      i -= 1;
      j -= 1;
    } else if (
      j > 0
      && (i === 0 || dp[i * cols + (j - 1)]! >= dp[(i - 1) * cols + j]!)
    ) {
      edits.push({ kind: 'insert', line: b[j - 1]! });
      j -= 1;
    } else {
      edits.push({ kind: 'delete', line: a[i - 1]! });
      i -= 1;
    }
  }
  edits.reverse();
  return edits;
}

interface UnifiedHunk {
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
  lines: string[];
}

/**
 * Build unified-diff text from before/after UTF-8 strings. Context radius is 3.
 */
export function buildUnifiedDiffText(options: {
  beforeText: string;
  afterText: string;
  oldPath: string;
  newPath: string;
}): string {
  const before = splitTextLines(options.beforeText);
  const after = splitTextLines(options.afterText);
  const edits = myersLineEdits(before.lines, after.lines);

  const CONTEXT = 3;
  const hunks: UnifiedHunk[] = [];
  let oldLine = 1;
  let newLine = 1;
  let i = 0;

  while (i < edits.length) {
    while (i < edits.length && edits[i]!.kind === 'equal') {
      oldLine += 1;
      newLine += 1;
      i += 1;
    }
    if (i >= edits.length) {
      break;
    }

    const changeStart = i;
    let changeEnd = i;
    while (changeEnd < edits.length) {
      if (edits[changeEnd]!.kind !== 'equal') {
        changeEnd += 1;
        continue;
      }
      let equalRun = 0;
      let j = changeEnd;
      while (j < edits.length && edits[j]!.kind === 'equal' && equalRun < CONTEXT * 2) {
        equalRun += 1;
        j += 1;
      }
      const moreChanges = j < edits.length && edits[j]!.kind !== 'equal';
      if (moreChanges && equalRun < CONTEXT * 2) {
        changeEnd = j;
        continue;
      }
      break;
    }

    const preContextStart = Math.max(0, changeStart - CONTEXT);
    // Count equal lines immediately before changeStart for old/new numbering rewind.
    let rewind = 0;
    for (let p = preContextStart; p < changeStart; p += 1) {
      if (edits[p]!.kind === 'equal') {
        rewind += 1;
      }
    }
    const hunkOldStart = oldLine - rewind;
    const hunkNewStart = newLine - rewind;

    let oldCount = 0;
    let newCount = 0;
    const hunkLines: string[] = [];

    for (let p = preContextStart; p < changeStart; p += 1) {
      hunkLines.push(` ${edits[p]!.line}`);
      oldCount += 1;
      newCount += 1;
    }

    for (let p = changeStart; p < changeEnd; p += 1) {
      const edit = edits[p]!;
      if (edit.kind === 'equal') {
        hunkLines.push(` ${edit.line}`);
        oldCount += 1;
        newCount += 1;
        oldLine += 1;
        newLine += 1;
      } else if (edit.kind === 'delete') {
        hunkLines.push(`-${edit.line}`);
        oldCount += 1;
        oldLine += 1;
      } else {
        hunkLines.push(`+${edit.line}`);
        newCount += 1;
        newLine += 1;
      }
    }

    let post = 0;
    while (changeEnd + post < edits.length && edits[changeEnd + post]!.kind === 'equal' && post < CONTEXT) {
      const edit = edits[changeEnd + post]!;
      hunkLines.push(` ${edit.line}`);
      oldCount += 1;
      newCount += 1;
      oldLine += 1;
      newLine += 1;
      post += 1;
    }
    i = changeEnd + post;

    hunks.push({
      oldStart: oldCount === 0 ? 0 : Math.max(1, hunkOldStart),
      oldCount,
      newStart: newCount === 0 ? 0 : Math.max(1, hunkNewStart),
      newCount,
      lines: hunkLines,
    });
  }

  // Identical files (including both empty): still emit headers with no hunks.
  const header = [
    `--- ${options.oldPath}`,
    `+++ ${options.newPath}`,
  ];
  const parts = [...header];
  for (const hunk of hunks) {
    const oldRange = hunk.oldCount === 1 ? `${hunk.oldStart}` : `${hunk.oldStart},${hunk.oldCount}`;
    const newRange = hunk.newCount === 1 ? `${hunk.newStart}` : `${hunk.newStart},${hunk.newCount}`;
    parts.push(`@@ -${oldRange} +${newRange} @@`);
    parts.push(...hunk.lines);
  }
  let text = `${parts.join('\n')}\n`;
  // Explicit markers help viewers; omit when a side has no lines.
  if (before.lines.length > 0 && !before.newlineAtEof) {
    text += '\\ No newline at end of file\n';
  }
  if (
    after.lines.length > 0
    && !after.newlineAtEof
    && (before.newlineAtEof || before.lines.length === 0 || options.beforeText !== options.afterText)
  ) {
    text += '\\ No newline at end of file\n';
  }
  return text;
}

/**
 * Resolve display paths for unified-diff headers.
 * Added uses `/dev/null` as the old path; deleted uses `/dev/null` as the new path.
 */
export function unifiedDiffPaths(
  change: Pick<GraphDiffChange, 'operation' | 'path' | 'fromPath'>,
): { oldPath: string; newPath: string } {
  switch (change.operation) {
    case 'added':
      return { oldPath: '/dev/null', newPath: `b/${change.path}` };
    case 'deleted':
      return { oldPath: `a/${change.path}`, newPath: '/dev/null' };
    case 'renamed':
      return {
        oldPath: `a/${change.fromPath ?? change.path}`,
        newPath: `b/${change.path}`,
      };
    case 'modified':
    default:
      return { oldPath: `a/${change.path}`, newPath: `b/${change.path}` };
  }
}

function resolveRenderLimits(limits?: GraphDiffRenderLimits): {
  maxPerFileChars: number;
  maxAggregateChars: number;
  maxLinesPerSide: number;
} {
  return {
    maxPerFileChars: limits?.maxPerFileChars ?? GRAPH_DIFF_MAX_PER_FILE_CHARS,
    maxAggregateChars: limits?.maxAggregateChars ?? GRAPH_DIFF_MAX_AGGREGATE_CHARS,
    maxLinesPerSide: limits?.maxLinesPerSide ?? GRAPH_DIFF_MAX_LINES_PER_SIDE,
  };
}

function truncateDiffText(text: string, maxChars: number): { text: string; truncated: boolean } {
  if (text.length <= maxChars) {
    return { text, truncated: false };
  }
  if (maxChars <= 0) {
    return { text: '', truncated: true };
  }
  const marker = '\n...[truncated]\n';
  if (maxChars <= marker.length) {
    return { text: text.slice(0, maxChars), truncated: true };
  }
  return { text: `${text.slice(0, maxChars - marker.length)}${marker}`, truncated: true };
}

/**
 * Attach unified-diff text to loaded changeset entries. Binary and unavailable
 * entries stay metadata-only. Per-file and aggregate caps set `truncated`.
 */
export function renderGraphDiffChanges(
  loaded: GraphDiffLoadedChange[],
  limits?: GraphDiffRenderLimits,
): { changes: GraphDiffChange[]; truncated: boolean } {
  const { maxPerFileChars, maxAggregateChars, maxLinesPerSide } = resolveRenderLimits(limits);
  const changes: GraphDiffChange[] = [];
  let truncated = false;
  let aggregateUsed = 0;

  for (const item of loaded) {
    const base: GraphDiffChange = { ...item.change };
    delete base.unifiedDiff;

    if (base.binary || base.unavailable) {
      changes.push(base);
      continue;
    }

    const remaining = maxAggregateChars - aggregateUsed;
    if (remaining <= 0) {
      truncated = true;
      changes.push(base);
      continue;
    }

    const beforeText = item.sides.beforeBytes ? item.sides.beforeBytes.toString('utf8') : '';
    const afterText = item.sides.afterBytes ? item.sides.afterBytes.toString('utf8') : '';
    const beforeLines = splitTextLines(beforeText).lines.length;
    const afterLines = splitTextLines(afterText).lines.length;

    if (beforeLines > maxLinesPerSide || afterLines > maxLinesPerSide) {
      truncated = true;
      changes.push(base);
      continue;
    }

    const paths = unifiedDiffPaths(base);
    let diffText = buildUnifiedDiffText({
      beforeText,
      afterText,
      oldPath: paths.oldPath,
      newPath: paths.newPath,
    });

    const perFileCap = Math.min(maxPerFileChars, remaining);
    const capped = truncateDiffText(diffText, perFileCap);
    if (capped.truncated) {
      truncated = true;
    }
    if (capped.text.length > 0) {
      base.unifiedDiff = capped.text;
      aggregateUsed += capped.text.length;
    } else {
      truncated = true;
    }
    changes.push(base);
  }

  return { changes, truncated };
}

function entrySha256(entry: unknown): string | undefined {
  if (!isJsonRecord(entry)) {
    return undefined;
  }
  return typeof entry['sha256'] === 'string' ? entry['sha256'] : undefined;
}

function entryType(entry: unknown): string | undefined {
  if (!isJsonRecord(entry)) {
    return undefined;
  }
  return typeof entry['type'] === 'string' ? entry['type'] : undefined;
}

/**
 * Resolve the changesetManifest string from a node state file, preferring the
 * node entry and falling back to the latest attempt (same precedence as detail).
 */
function resolveNodeChangesetManifest(raw: Record<string, unknown>): string | null {
  if (typeof raw['changesetManifest'] === 'string' && raw['changesetManifest'].trim()) {
    return raw['changesetManifest'];
  }
  const attempts = Array.isArray(raw['attempts']) ? raw['attempts'] : [];
  for (let i = attempts.length - 1; i >= 0; i -= 1) {
    const attempt = attempts[i];
    if (
      isJsonRecord(attempt)
      && typeof attempt['changesetManifest'] === 'string'
      && attempt['changesetManifest'].trim()
    ) {
      return attempt['changesetManifest'];
    }
  }
  return null;
}

function emptyNodeResult(nodeId: string, changesetManifest: string | null): GraphDiffNodeResult {
  return {
    nodeId,
    changesetManifest,
    changes: [],
  };
}

function readSourceBasePath(runDir: string): string | null {
  const runJson = safeReadJson(join(runDir, 'run.json'));
  const sourceBase = runJson['sourceBase'];
  if (!isJsonRecord(sourceBase)) {
    return null;
  }
  const sourcePath = sourceBase['sourcePath'];
  if (typeof sourcePath !== 'string' || !sourcePath.trim()) {
    return null;
  }
  return resolvePathUnderRoot(runDir, sourcePath.trim());
}

function readFileIfPresent(absPath: string): Buffer | null {
  if (!existsSync(absPath)) {
    return null;
  }
  try {
    return readFileSync(absPath);
  } catch {
    return null;
  }
}

/**
 * Load one changeset change entry under `runDir` without Git and without
 * recomputing node keys. Missing sides for added/deleted are never opened.
 * Escaping blob / source-base paths are refused after normalization.
 */
export function loadGraphDiffChange(
  runDir: string,
  manifestAbsPath: string,
  rawChange: Record<string, unknown>,
  sourceBaseAbs: string | null,
): GraphDiffLoadedChange | null {
  const operation = asOperation(rawChange['operation']);
  const path = typeof rawChange['path'] === 'string' ? rawChange['path'] : '';
  if (!operation || !path) {
    return null;
  }

  const fromPath =
    typeof rawChange['fromPath'] === 'string' && rawChange['fromPath'].trim()
      ? rawChange['fromPath'].trim()
      : undefined;

  const before = rawChange['before'];
  const after = rawChange['after'];
  const beforeSha256 = entrySha256(before);
  const afterSha256 = entrySha256(after);
  const binaryFlag = rawChange['binary'] === true;
  const afterType = entryType(after);
  const afterIsFile =
    afterType === 'file'
    || (afterType === undefined && typeof rawChange['blob'] === 'string');

  const needsBefore = operation === 'modified' || operation === 'deleted' || operation === 'renamed';
  const needsAfter = operation === 'added' || operation === 'modified' || operation === 'renamed';

  let beforeBytes: Buffer | null = null;
  let afterBytes: Buffer | null = null;
  const skippedBefore = !needsBefore;
  let skippedAfter = !needsAfter;
  let unavailable = false;

  if (needsBefore) {
    const beforeRel = operation === 'renamed' && fromPath ? fromPath : path;
    const beforeAbs =
      sourceBaseAbs && !beforeRel.includes('\0')
        ? resolvePathUnderRoot(sourceBaseAbs, beforeRel)
        : null;
    // Before path must stay under both sourceBase and the run directory.
    if (!beforeAbs || resolvePathUnderRoot(runDir, beforeAbs) === null) {
      unavailable = true;
    } else {
      beforeBytes = readFileIfPresent(beforeAbs);
      if (beforeBytes === null) {
        unavailable = true;
      } else if (beforeSha256 && sha256Hex(beforeBytes) !== beforeSha256) {
        // Hash mismatch: keep metadata, drop the body.
        unavailable = true;
        beforeBytes = null;
      }
    }
  }

  if (needsAfter && afterIsFile) {
    const blobRel = typeof rawChange['blob'] === 'string' ? rawChange['blob'] : '';
    const manifestDir = dirname(manifestAbsPath);
    const blobAbs =
      blobRel && !blobRel.includes('\0')
        ? resolvePathUnderRoot(manifestDir, blobRel)
        : null;
    if (!blobAbs || resolvePathUnderRoot(runDir, blobAbs) === null) {
      unavailable = true;
      afterBytes = null;
    } else {
      afterBytes = readFileIfPresent(blobAbs);
      if (afterBytes === null) {
        unavailable = true;
      }
    }
  } else if (needsAfter && !afterIsFile) {
    // Directories / symlinks have no blob body; metadata only.
    skippedAfter = true;
  }

  const detectedBinary =
    binaryFlag
    || (afterBytes !== null && afterBytes.subarray(0, 8192).includes(0))
    || (beforeBytes !== null && beforeBytes.subarray(0, 8192).includes(0));

  const change: GraphDiffChange = {
    path,
    operation,
    ...(fromPath ? { fromPath } : {}),
    binary: detectedBinary,
    unavailable,
    ...(beforeSha256 ? { beforeSha256 } : {}),
    ...(afterSha256 ? { afterSha256 } : {}),
  };

  return {
    change,
    sides: {
      beforeBytes,
      afterBytes,
      skippedBefore,
      skippedAfter,
    },
  };
}

/**
 * Read a node's declared changesetManifest directly (never recompute keys,
 * never use Git). Missing / escaping / unreadable manifests yield an empty
 * changes array.
 */
export function loadChangesFromManifest(
  runDir: string,
  changesetManifest: string,
): GraphDiffLoadedChange[] {
  const manifestAbs = resolvePathUnderRoot(runDir, changesetManifest);
  if (!manifestAbs || !existsSync(manifestAbs)) {
    return [];
  }

  const raw = safeReadJson(manifestAbs);
  const changesRaw = Array.isArray(raw['changes']) ? raw['changes'] : [];
  const sourceBaseAbs = readSourceBasePath(runDir);
  const loaded: GraphDiffLoadedChange[] = [];

  for (const entry of changesRaw) {
    if (!isJsonRecord(entry)) {
      continue;
    }
    const item = loadGraphDiffChange(runDir, manifestAbs, entry, sourceBaseAbs);
    if (item) {
      loaded.push(item);
    }
  }
  return loaded;
}

/**
 * Read-only graph-run changeset diff endpoint.
 *
 * Nodes without a `changesetManifest` return HTTP 200 with an empty `changes`
 * array. Manifest reading resolves declared paths under the run directory,
 * refuses escapes, and verifies before hashes without Git.
 */
export async function handleGraphRunDiffRequest(req: Request, res: Response): Promise<void> {
  const namespace = String(req.params['namespace'] ?? '').trim();
  const runId = String(req.params['runId'] ?? '').trim();

  if (!isValidGraphRunSegment(namespace) || !isValidGraphRunSegment(runId)) {
    res.status(400).json({ error: 'Invalid namespace or runId' });
    return;
  }

  const nodeIdRaw = req.query['nodeId'];
  const nodeId =
    typeof nodeIdRaw === 'string' ? nodeIdRaw.trim() : Array.isArray(nodeIdRaw) ? String(nodeIdRaw[0] ?? '').trim() : '';
  if (nodeId && !isValidGraphRunSegment(nodeId)) {
    res.status(400).json({ error: 'Invalid nodeId' });
    return;
  }

  const workspaceRootQuery = String(req.query['workspaceRoot'] ?? '').trim();
  let runDir: string;
  try {
    runDir = resolveGraphRunDir(workspaceRootQuery, namespace, runId);
  } catch {
    res.status(400).json({ error: 'Invalid namespace or runId' });
    return;
  }

  if (!existsSync(runDir)) {
    res.status(404).json({ error: 'Run not found' });
    return;
  }

  const nodes: GraphDiffNodeResult[] = [];
  let truncated = false;
  const nodesDir = join(runDir, 'nodes');

  // Collect loaded changes across nodes first so the aggregate budget is shared.
  const pending: Array<{
    nodeId: string;
    changesetManifest: string | null;
    loaded: GraphDiffLoadedChange[];
  }> = [];

  if (existsSync(nodesDir)) {
    try {
      const nodeFiles = await fs.readdir(nodesDir);
      for (const file of nodeFiles.sort()) {
        if (!file.endsWith('.json')) {
          continue;
        }
        const raw = safeReadJson(join(nodesDir, file));
        const id = typeof raw['nodeId'] === 'string' ? raw['nodeId'] : file.replace(/\.json$/, '');
        if (nodeId && id !== nodeId) {
          continue;
        }
        const changesetManifest = resolveNodeChangesetManifest(raw);
        if (!changesetManifest) {
          pending.push({ nodeId: id, changesetManifest: null, loaded: [] });
          continue;
        }
        pending.push({
          nodeId: id,
          changesetManifest,
          loaded: loadChangesFromManifest(runDir, changesetManifest),
        });
      }
    } catch {
      // Malformed nodes dir is treated as no nodes.
    }
  }

  const allLoaded = pending.flatMap((entry) => entry.loaded);
  const rendered = renderGraphDiffChanges(allLoaded);
  truncated = rendered.truncated;

  let offset = 0;
  for (const entry of pending) {
    if (!entry.changesetManifest) {
      nodes.push(emptyNodeResult(entry.nodeId, null));
      continue;
    }
    const slice = rendered.changes.slice(offset, offset + entry.loaded.length);
    offset += entry.loaded.length;
    nodes.push({
      nodeId: entry.nodeId,
      changesetManifest: entry.changesetManifest,
      changes: slice,
    });
  }

  const body: GraphRunDiffResponse = {
    namespace,
    runId,
    beforeImagePruned: safeReadJson(join(runDir, 'run.json'))['basePruned'] === true,
    nodes,
    truncated,
  };
  res.json(body);
}

export const GRAPH_RUN_DIFF_ROUTE = '/api/graph-runs/:namespace/:runId/diff';

export function registerGraphRunDiffRoutes(app: Express): void {
  app.get(GRAPH_RUN_DIFF_ROUTE, (req, res) => {
    void handleGraphRunDiffRequest(req, res);
  });
}
