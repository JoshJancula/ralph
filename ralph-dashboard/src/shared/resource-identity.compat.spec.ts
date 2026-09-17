import { ResourceIdentityBuilder } from './resource-identity';

describe('ResourceIdentity Backwards Compatibility', () => {
  it('should maintain compatibility with existing file navigation patterns', () => {
    const legacyParams = {
      root: 'plans',
      path: 'PLAN17.md',
      projectRoot: '/home/user/project',
    };

    const identity = ResourceIdentityBuilder.forPlan(
      legacyParams.projectRoot,
      legacyParams.path,
      'PLAN17'
    );

    expect(identity.root).toBe(legacyParams.root);
    expect(identity.path).toBe(legacyParams.path);
    expect(identity.projectRoot).toBe(legacyParams.projectRoot);
  });

  it('should support filename-only queries with proper project root', () => {
    const projects = [
      '/home/alice/workspace',
      '/home/bob/workspace',
    ];

    const filename = 'PLAN17.md';

    const identities = projects.map((projectRoot) =>
      ResourceIdentityBuilder.forPlan(projectRoot, filename, filename)
    );

    expect(identities[0].id).not.toBe(identities[1].id);
    expect(identities[0].projectRoot).not.toBe(identities[1].projectRoot);
    expect(identities[0].path).toBe(identities[1].path);
  });

  it('should preserve display name for backward compatible UI', () => {
    const identity = ResourceIdentityBuilder.forPlan(
      '/home/user/project',
      'plans/PLAN17.md',
      'PLAN17'
    );

    expect(identity.displayName).toBe('PLAN17');
  });

  it('should track provenance for source vs control copies', () => {
    const projectRoot = '/home/user/project';

    const source = ResourceIdentityBuilder.forPlan(projectRoot, 'plans/PLAN1.md', 'PLAN1', 'source');
    const control = ResourceIdentityBuilder.forPlan(projectRoot, 'plans/.plan/PLAN1.md', 'PLAN1', 'control');

    expect(source.source).toBe('source');
    expect(control.source).toBe('control');
  });

  it('should support nested path structures from existing logs', () => {
    const paths = [
      'logs/PLAN17/run-001/output.log',
      'logs/PLAN17/run-002/output.log',
      'logs/PLAN17/run-latest/output.log',
    ];

    const identities = paths.map((path) =>
      ResourceIdentityBuilder.forLog('/home/user/project', path, path.split('/').pop() || 'log')
    );

    const uniqueIds = new Set(identities.map((id) => id.id));
    expect(uniqueIds.size).toBe(paths.length);
  });

  it('should support workspace aggregation patterns', () => {
    const workspaces = [
      { path: 'workspace1', projectRoot: '/data/project1' },
      { path: 'workspace2', projectRoot: '/data/project2' },
    ];

    const identities = workspaces.map((ws) =>
      ResourceIdentityBuilder.forLog(ws.projectRoot, 'logs/PLAN1/output.log', 'output.log')
    );

    const ids = identities.map((id) => id.id);
    expect(new Set(ids).size).toBe(identities.length);
  });

  it('should maintain compatibility with existing log resolution patterns', () => {
    const identity = ResourceIdentityBuilder.forLog(
      '/home/user/project',
      'logs/PLAN17/run-001/output.log',
      'output.log'
    );

    expect(identity.root).toBe('logs');
    expect(identity.kind).toBe('log');
    expect(identity.path).toContain('PLAN17');
    expect(identity.path).toContain('run-001');
  });

  it('should support metadata extraction from identity', () => {
    const identity = ResourceIdentityBuilder.forPlan(
      '/home/user/project',
      'plans/PLAN17.md',
      'PLAN17',
      'source'
    );

    const extractedMetadata = {
      kind: identity.kind,
      root: identity.root,
      filename: identity.path.split('/').pop(),
      directory: identity.path.substring(0, identity.path.lastIndexOf('/')),
      projectRoot: identity.projectRoot,
      source: identity.source,
    };

    expect(extractedMetadata.kind).toBe('plan');
    expect(extractedMetadata.root).toBe('plans');
    expect(extractedMetadata.filename).toBe('PLAN17.md');
    expect(extractedMetadata.directory).toBe('plans');
  });

  it('should handle duplicate names gracefully during display', () => {
    const projects = [
      { root: '/project/alice', name: 'Alice Project' },
      { root: '/project/bob', name: 'Bob Project' },
    ];

    const duplicates = projects.map((proj) =>
      ResourceIdentityBuilder.forPlan(proj.root, 'PLAN1.md', 'PLAN1')
    );

    const disambiguationData = duplicates.map((id) => ({
      displayName: id.displayName,
      id: id.id,
      projectPath: id.projectRoot.split('/').slice(-2).join('/'),
    }));

    expect(disambiguationData[0].id).not.toBe(disambiguationData[1].id);
    expect(disambiguationData[0].projectPath).toBe('project/alice');
    expect(disambiguationData[1].projectPath).toBe('project/bob');
  });
});
