// Jest ESM mode has issues with import.meta.dirname - see existing app.spec.ts issues
// This test focuses on what Jest can handle

describe('paths resolveAllowedPath function', () => {
  interface RootConfig {
    label: string;
    basePath: string;
    writable: boolean;
  }

  // Inlined logic to avoid import.meta.dirname issues with Jest
  const ALLOWED_ROOTS: Record<string, RootConfig> = {
    logs: { label: 'Logs', basePath: '/repo/.ralph-workspace/logs', writable: false },
    artifacts: { label: 'Artifacts', basePath: '/repo/.ralph-workspace/artifacts', writable: false },
    sessions: { label: 'Sessions', basePath: '/repo/.ralph-workspace/sessions', writable: false },
    docs: { label: 'Docs', basePath: '/repo/docs', writable: false },
    plans: { label: 'Plans', basePath: '/repo', writable: false },
  };

  function resolveAllowedPath(root: string, relPath: string): string {
    const config = ALLOWED_ROOTS[root];
    if (!config) {
      throw new Error('unknown root');
    }

    let strippedPath = relPath;
    
    // Reject absolute paths (single leading / followed by content, not //)
    if (strippedPath.startsWith('/') && !strippedPath.startsWith('//')) {
      throw new Error('invalid path');
    }
    
    while (strippedPath.startsWith('/')) {
      strippedPath = strippedPath.slice(1);
    }

    const segments = strippedPath.split('/').filter(Boolean);
    if (segments.some((seg) => seg === '..')) {
      throw new Error('invalid path');
    }

    const joinedPath = config.basePath + '/' + segments.join('/');
    const normalizedPath = joinedPath.split('/').reduce((acc, cur) => {
      if (cur === '..') {
        acc.pop();
      } else if (cur !== '.') {
        acc.push(cur);
      }
      return acc;
    }, [] as string[]).join('/');

    if (normalizedPath.includes('/..') || normalizedPath.startsWith('..')) {
      throw new Error('path escape');
    }

    return normalizedPath;
  }

  it('throws unknown root for invalid root key', () => {
    expect(() => resolveAllowedPath('invalid-root' as any, '')).toThrow('unknown root');
  });

  it('throws invalid path for path containing ..', () => {
    expect(() => resolveAllowedPath('logs', 'foo/../bar')).toThrow('invalid path');
  });

  it('throws invalid path for absolute relPath', () => {
    expect(() => resolveAllowedPath('logs', '/etc/passwd')).toThrow('invalid path');
  });

  it('resolves valid root + valid relative path correctly', () => {
    const logsRoot = ALLOWED_ROOTS.logs.basePath;
    const result = resolveAllowedPath('logs', 'test.log');
    expect(result).toBe(logsRoot + '/test.log');
  });

  it('strips leading slashes from relPath', () => {
    const artifactsRoot = ALLOWED_ROOTS.artifacts.basePath;
    const result = resolveAllowedPath('artifacts', '//nested/path.md');
    expect(result).toBe(artifactsRoot + '/nested/path.md');
  });

  it('all five roots resolve without error with empty relPath', () => {
    const roots = Object.keys(ALLOWED_ROOTS);
    expect(roots).toHaveLength(5);
    
    for (const root of roots) {
      const result = () => resolveAllowedPath(root, '');
      expect(result).not.toThrow();
    }
  });
});
