import type { Express, Request, Response } from 'express';
import { existsSync, promises as fs } from 'node:fs';
import { join } from 'node:path';

import {
  findWorkspaceProjectRoot,
  getAllowedRoots,
  parentListingPath,
  resolveUnderRoot,
  type RootConfig,
} from '../paths.js';

const FILE_CHUNK_BYTES = 256 * 1024;

function jsonError(res: Response, status: number, message: string): void {
  res.status(status).json({ error: message });
}

function getRootsMap(): Record<string, RootConfig> {
  return getAllowedRoots(findWorkspaceProjectRoot());
}

export function registerDashboardApi(app: Express): void {
  app.get('/api/roots', (_req: Request, res: Response) => {
    const roots = getRootsMap();
    const body = Object.entries(roots).map(([key, config]) => ({
      key,
      label: config.label,
      exists: existsSync(config.basePath),
    }));
    res.json(body);
  });

  app.get('/api/list', async (req: Request, res: Response) => {
    const rootKey = req.query['root'] as string | undefined;
    const pathParam = (req.query['path'] as string | undefined) ?? '';
    if (!rootKey) {
      return jsonError(res, 400, 'missing root');
    }

    const roots = getRootsMap();
    const config = roots[rootKey];
    if (!config) {
      return jsonError(res, 400, 'unknown root');
    }

    let absDir: string;
    try {
      absDir = resolveUnderRoot(config, pathParam);
    } catch {
      return jsonError(res, 400, 'invalid path');
    }

    let stat: Awaited<ReturnType<typeof fs.stat>>;
    try {
      stat = await fs.stat(absDir);
    } catch {
      return jsonError(res, 404, 'not found');
    }

    if (!stat.isDirectory()) {
      return jsonError(res, 400, 'not a directory');
    }

    let names: string[];
    try {
      names = await fs.readdir(absDir);
    } catch {
      return jsonError(res, 500, 'read failed');
    }

    names.sort((a, b) => a.localeCompare(b));

    const entries: Array<{
      name: string;
      path: string;
      type: 'file' | 'dir';
      size: number;
      mtime: number;
    }> = [];

    const relPrefix = pathParam ? (pathParam.endsWith('/') ? pathParam : `${pathParam}/`) : '';

    for (const name of names) {
      if (name.startsWith('.')) {
        continue;
      }
      const absChild = join(absDir, name);
      let st: Awaited<ReturnType<typeof fs.stat>>;
      try {
        st = await fs.stat(absChild);
      } catch {
        continue;
      }
      const isDir = st.isDirectory();
      const relPath = isDir ? `${relPrefix}${name}/` : `${relPrefix}${name}`;
      entries.push({
        name,
        path: relPath,
        type: isDir ? 'dir' : 'file',
        size: st.size,
        mtime: Math.floor(st.mtimeMs),
      });
    }

    // Filter plan files to only show files with corresponding logs directories
    let filteredEntries = entries;
    if (rootKey === 'plans' && !pathParam) {
      const logsConfig = getRootsMap()['logs'];
      if (logsConfig && existsSync(logsConfig.basePath)) {
        filteredEntries = [];
        for (const entry of entries) {
          // Skip directories - only show files
          if (entry.type === 'dir') {
            continue;
          }
          // For files, check if there's a corresponding directory in logs with matching name
          const fileName = entry.name;
          // Try with the full filename (without extension) as directory name
          const fileNameWithoutExt = fileName.includes('.')
            ? fileName.substring(0, fileName.lastIndexOf('.'))
            : fileName;
          const logsPlanDir = join(logsConfig.basePath, fileNameWithoutExt);
          try {
            const logsStat = await fs.stat(logsPlanDir);
            if (logsStat.isDirectory()) {
              filteredEntries.push(entry);
            }
          } catch {
            // Corresponding logs directory doesn't exist, skip this file
          }
        }
      }
    }

    res.json({
      root: rootKey,
      path: pathParam,
      parent: parentListingPath(pathParam),
      entries: filteredEntries,
    });
  });

  app.get('/api/file', async (req: Request, res: Response) => {
    const rootKey = req.query['root'] as string | undefined;
    const filePath = (req.query['path'] as string | undefined) ?? '';
    const offsetRaw = (req.query['offset'] as string | undefined) ?? '0';
    const offset = Number.parseInt(offsetRaw, 10);
    if (!rootKey || Number.isNaN(offset) || offset < 0) {
      return jsonError(res, 400, 'bad request');
    }

    const roots = getRootsMap();
    const config = roots[rootKey];
    if (!config) {
      return jsonError(res, 400, 'unknown root');
    }

    let absFile: string;
    try {
      absFile = resolveUnderRoot(config, filePath);
    } catch {
      return jsonError(res, 400, 'invalid path');
    }

    let stat: Awaited<ReturnType<typeof fs.stat>>;
    try {
      stat = await fs.stat(absFile);
    } catch {
      return jsonError(res, 404, 'file not found');
    }

    if (!stat.isFile()) {
      return jsonError(res, 400, 'not a file');
    }

    const size = stat.size;
    if (offset > size) {
      return res.json({
        content: '',
        size,
        offset,
        nextOffset: size,
      });
    }

    const length = Math.min(FILE_CHUNK_BYTES, size - offset);
    const handle = await fs.open(absFile, 'r');
    try {
      const buf = Buffer.alloc(length);
      const { bytesRead } = await handle.read(buf, 0, length, offset);
      const content = buf.subarray(0, bytesRead).toString('utf8');
      const nextOffset = offset + bytesRead;
      res.json({
        content,
        size,
        offset,
        nextOffset,
      });
    } finally {
      await handle.close();
    }
  });

  app.get('/api/template', async (req: Request, res: Response) => {
    const name = req.query['name'] as string | undefined;
    if (!name || (name !== 'plan' && name !== 'orchestration')) {
      return jsonError(res, 400, 'invalid template name');
    }

    const workspaceRoot = findWorkspaceProjectRoot();
    const roots = getAllowedRoots(workspaceRoot);
    const plans = roots['plans'];
    if (!plans) {
      return jsonError(res, 500, 'config');
    }

    const rel = name === 'plan' ? '.ralph/plan.template' : '.ralph/orchestration.template.json';
    let absPath: string;
    try {
      absPath = resolveUnderRoot(plans, rel);
    } catch {
      return jsonError(res, 404, 'template not found');
    }

    try {
      const text = await fs.readFile(absPath, 'utf8');
      res.json({ name, content: text });
    } catch {
      return jsonError(res, 404, 'template not found');
    }
  });
}
