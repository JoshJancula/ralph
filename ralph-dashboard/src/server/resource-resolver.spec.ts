import { ResourceResolver, isResourceResolveError } from './resource-resolver';
import { existsSync } from 'node:fs';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

describe('ResourceResolver', () => {
  let resolver: ResourceResolver;
  let tempRoot: string;

  beforeEach(() => {
    tempRoot = mkdtempSync(join(tmpdir(), 'resource-resolver-'));
    resolver = new ResourceResolver({
      'logs': join(tempRoot, 'logs'),
      'plans': join(tempRoot, 'plans'),
      'artifacts': join(tempRoot, 'artifacts'),
    });
  });

  describe('resolveResource', () => {
    it('should resolve a valid path within allowed root', () => {
      const result = resolver.resolveResource('plans', 'PLAN17.md');
      expect(result).not.toHaveProperty('code');
      if (!('code' in result)) {
        expect(result.root).toBe('plans');
        expect(result.path).toBe('PLAN17.md');
        expect(result.absolutePath).toContain('PLAN17.md');
      }
    });

    it('should detect traversal attempts with ..', () => {
      const result = resolver.resolveResource('plans', '../logs/file.log');
      expect(isResourceResolveError(result)).toBe(true);
      if (isResourceResolveError(result)) {
        expect(result.code).toBe('TRAVERSAL_ATTEMPT');
      }
    });

    it('should detect absolute path traversal attempts', () => {
      const result = resolver.resolveResource('plans', '/etc/passwd');
      expect(isResourceResolveError(result)).toBe(true);
      if (isResourceResolveError(result)) {
        expect(result.code).toBe('TRAVERSAL_ATTEMPT');
      }
    });

    it('should reject unknown root', () => {
      const result = resolver.resolveResource('unknown', 'file.log');
      expect(isResourceResolveError(result)).toBe(true);
      if (isResourceResolveError(result)) {
        expect(result.code).toBe('INVALID_ROOT');
      }
    });

    it('should set exists flag correctly', () => {
      const plansRoot = join(tempRoot, 'plans');
      mkdirSync(plansRoot, { recursive: true });
      const testFile = join(plansRoot, 'test.md');
      writeFileSync(testFile, 'test content');

      const existingResult = resolver.resolveResource('plans', 'test.md');
      expect(existingResult).not.toHaveProperty('code');
      if (!('code' in existingResult)) {
        expect(existingResult.exists).toBe(true);
      }

      const nonexistentResult = resolver.resolveResource('plans', 'nonexistent.md');
      expect(nonexistentResult).not.toHaveProperty('code');
      if (!('code' in nonexistentResult)) {
        expect(nonexistentResult.exists).toBe(false);
      }
    });

    it('should respect projectRoot when provided', () => {
      const subproject = join(tempRoot, 'projects', 'my-project');
      const projectPlans = join(subproject, 'plans');

      resolver = new ResourceResolver({
        'logs': join(tempRoot, 'logs'),
        'plans': projectPlans,
        'artifacts': join(tempRoot, 'artifacts'),
      });

      const result = resolver.resolveResource('plans', 'test.md', subproject);
      expect(result).not.toHaveProperty('code');
      if (!('code' in result)) {
        expect(result.projectRoot).toBe(subproject);
      }
    });

    it('should reject a traversal attempt in projectRoot', () => {
      const result = resolver.resolveResource('plans', 'test.md', `${tempRoot}/../outside`);
      expect(isResourceResolveError(result)).toBe(true);
      if (isResourceResolveError(result)) {
        expect(result.code).toBe('NOT_IN_PROJECT');
      }
    });

    it('should handle nested paths safely', () => {
      const result = resolver.resolveResource('logs', 'PLAN17/run-001/2024-01-15/output.log');
      expect(result).not.toHaveProperty('code');
      if (!('code' in result)) {
        expect(result.path).toBe('PLAN17/run-001/2024-01-15/output.log');
        expect(result.absolutePath).toContain('PLAN17');
      }
    });

    it('should handle empty path', () => {
      const result = resolver.resolveResource('plans', '');
      expect(result).not.toHaveProperty('code');
      if (!('code' in result)) {
        expect(result.absolutePath).toBe(join(tempRoot, 'plans'));
      }
    });
  });

  describe('distinguishing resources in different projects', () => {
    it('should resolve same filename in different projects to different paths', () => {
      const project1 = join(tempRoot, 'project1');
      const project2 = join(tempRoot, 'project2');

      resolver = new ResourceResolver({
        'plans': join(tempRoot, 'plans'),
      });

      const result1 = resolver.resolveResource('plans', 'PLAN17.md', project1);
      const result2 = resolver.resolveResource('plans', 'PLAN17.md', project2);

      expect(result1).not.toHaveProperty('code');
      expect(result2).not.toHaveProperty('code');

      if (!('code' in result1) && !('code' in result2)) {
        expect(result1.projectRoot).not.toBe(result2.projectRoot);
        expect(result1.absolutePath).not.toBe(result2.absolutePath);
      }
    });
  });
});

describe('isResourceResolveError', () => {
  it('should identify resource resolve errors', () => {
    const error = {
      code: 'TRAVERSAL_ATTEMPT',
      message: 'Invalid path',
    };
    expect(isResourceResolveError(error)).toBe(true);
  });

  it('should identify valid resolve results as non-errors', () => {
    const result = {
      projectRoot: '/home/user',
      root: 'plans',
      path: 'PLAN17.md',
      absolutePath: '/home/user/plans/PLAN17.md',
      exists: true,
    };
    expect(isResourceResolveError(result)).toBe(false);
  });

  it('should reject invalid error codes', () => {
    const invalid = {
      code: 'UNKNOWN_ERROR',
      message: 'Something happened',
    };
    expect(isResourceResolveError(invalid)).toBe(false);
  });

  it('should require both code and message', () => {
    expect(isResourceResolveError({ code: 'TRAVERSAL_ATTEMPT' })).toBe(false);
    expect(isResourceResolveError({ message: 'error message' })).toBe(false);
  });
});
