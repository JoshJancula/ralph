import { resolve, isAbsolute } from 'node:path';
import { existsSync, statSync } from 'node:fs';

export interface ResolvedResource {
  projectRoot: string;
  root: string;
  path: string;
  absolutePath: string;
  exists: boolean;
}

export interface ResourceResolveError {
  code: 'TRAVERSAL_ATTEMPT' | 'INVALID_ROOT' | 'NOT_FOUND' | 'NOT_IN_PROJECT';
  message: string;
  requestedPath?: string;
  requestedRoot?: string;
}

export class ResourceResolver {
  private allowedRoots: Map<string, string>;

  constructor(rootMapping: Record<string, string>) {
    this.allowedRoots = new Map(Object.entries(rootMapping));
  }

  resolveResource(root: string, path: string, projectRoot?: string): ResolvedResource | ResourceResolveError {
    if (this.isTraversalAttempt(path)) {
      return {
        code: 'TRAVERSAL_ATTEMPT',
        message: `Invalid path: contains .. or absolute reference`,
        requestedPath: path,
        requestedRoot: root,
      };
    }

    if (!this.allowedRoots.has(root)) {
      return {
        code: 'INVALID_ROOT',
        message: `Unknown root: ${root}`,
        requestedRoot: root,
      };
    }

    const rootBase = this.allowedRoots.get(root)!;
    let basePath = rootBase;

    if (projectRoot) {
      if (projectRoot.replace(/\\/g, '/').includes('..')) {
        return {
          code: 'NOT_IN_PROJECT',
          message: `Project root must not contain a traversal segment`,
          requestedRoot: root,
        };
      }

      basePath = resolve(projectRoot);
    }

    const absolutePath = resolve(basePath, path);

    if (!absolutePath.startsWith(basePath)) {
      return {
        code: 'NOT_IN_PROJECT',
        message: `Resolved path is outside project root`,
        requestedPath: path,
        requestedRoot: root,
      };
    }

    const exists = existsSync(absolutePath);

    return {
      projectRoot: basePath,
      root,
      path,
      absolutePath,
      exists,
    };
  }

  private isTraversalAttempt(path: string): boolean {
    if (!path) {
      return false;
    }
    const normalized = path.replace(/\\/g, '/');
    return normalized.includes('..') || normalized.startsWith('/') || isAbsolute(path);
  }
}

export function isResourceResolveError(value: unknown): value is ResourceResolveError {
  if (!value || typeof value !== 'object') {
    return false;
  }
  const obj = value as Record<string, unknown>;
  return (
    typeof obj['code'] === 'string' &&
    typeof obj['message'] === 'string' &&
    (obj['code'] === 'TRAVERSAL_ATTEMPT' ||
      obj['code'] === 'INVALID_ROOT' ||
      obj['code'] === 'NOT_FOUND' ||
      obj['code'] === 'NOT_IN_PROJECT')
  );
}
