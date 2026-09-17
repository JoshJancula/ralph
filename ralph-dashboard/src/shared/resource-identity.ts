export type ResourceKind = 'plan' | 'log' | 'artifact' | 'session' | 'workflow' | 'run' | 'discover-report';

export interface ResourceIdentity {
  projectRoot: string;
  root: string;
  kind: ResourceKind;
  path: string;
  displayName: string;
  id: string;
  source?: 'source' | 'control' | 'generated';
}

export class ResourceIdentityCodec {
  static encode(identity: ResourceIdentity): string {
    const data = {
      projectRoot: identity.projectRoot,
      root: identity.root,
      kind: identity.kind,
      path: identity.path,
      displayName: identity.displayName,
      id: identity.id,
      ...(identity.source && { source: identity.source }),
    };
    const json = JSON.stringify(data);
    return Buffer.from(json).toString('base64url');
  }

  static decode(encoded: string): ResourceIdentity {
    try {
      const json = Buffer.from(encoded, 'base64url').toString('utf8');
      const data = JSON.parse(json) as unknown;
      if (!this.isValidResourceIdentity(data)) {
        throw new Error('Invalid resource identity');
      }
      return data;
    } catch (error) {
      throw new Error(`Failed to decode resource identity: ${error instanceof Error ? error.message : 'unknown error'}`);
    }
  }

  private static isValidResourceIdentity(data: unknown): data is ResourceIdentity {
    if (!data || typeof data !== 'object') {
      return false;
    }
    const obj = data as Record<string, unknown>;
    return (
      typeof obj['projectRoot'] === 'string' &&
      typeof obj['root'] === 'string' &&
      typeof obj['kind'] === 'string' &&
      typeof obj['path'] === 'string' &&
      typeof obj['displayName'] === 'string' &&
      typeof obj['id'] === 'string' &&
      (obj['source'] === undefined || typeof obj['source'] === 'string')
    );
  }
}

export class ResourceIdentityBuilder {
  static forPlan(projectRoot: string, path: string, displayName: string, source?: 'source' | 'control' | 'generated'): ResourceIdentity {
    return {
      projectRoot,
      root: 'plans',
      kind: 'plan',
      path,
      displayName,
      id: createStableId('plan', projectRoot, path),
      source,
    };
  }

  static forLog(projectRoot: string, path: string, displayName: string): ResourceIdentity {
    return {
      projectRoot,
      root: 'logs',
      kind: 'log',
      path,
      displayName,
      id: createStableId('log', projectRoot, path),
    };
  }

  static forArtifact(projectRoot: string, path: string, displayName: string): ResourceIdentity {
    return {
      projectRoot,
      root: 'artifacts',
      kind: 'artifact',
      path,
      displayName,
      id: createStableId('artifact', projectRoot, path),
    };
  }

  static forWorkflow(projectRoot: string, path: string, displayName: string): ResourceIdentity {
    return {
      projectRoot,
      root: 'workflows',
      kind: 'workflow',
      path,
      displayName,
      id: createStableId('workflow', projectRoot, path),
    };
  }

  static forRun(projectRoot: string, path: string, displayName: string): ResourceIdentity {
    return {
      projectRoot,
      root: 'runs',
      kind: 'run',
      path,
      displayName,
      id: createStableId('run', projectRoot, path),
    };
  }

  static forDiscoverReport(projectRoot: string, path: string, displayName: string): ResourceIdentity {
    return {
      projectRoot,
      root: 'artifacts',
      kind: 'discover-report',
      path,
      displayName,
      id: createStableId('discover-report', projectRoot, path),
    };
  }
}

function createStableId(kind: string, projectRoot: string, path: string): string {
  const combined = `${kind}:${projectRoot}:${path}`;
  // Hash before truncating: a raw base64-then-substring encoding drops the tail of long
  // inputs, so two paths that only differ near the end (a long shared projectRoot prefix)
  // collide. A hash mixes every input byte, so truncating its digest stays collision-safe.
  let h1 = 0x811c9dc5;
  let h2 = (0x1000193 ^ combined.length) >>> 0;
  for (let i = 0; i < combined.length; i++) {
    const c = combined.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 16777619) >>> 0;
    h2 = Math.imul(h2 ^ c, 2246822519) >>> 0;
  }
  const digest = Buffer.alloc(8);
  digest.writeUInt32BE(h1, 0);
  digest.writeUInt32BE(h2, 4);
  return digest.toString('base64url');
}

export function isTraversalAttempt(path: string): boolean {
  if (!path) {
    return false;
  }
  const normalized = path.replace(/\\/g, '/');
  return normalized.includes('..') || normalized.startsWith('/');
}
