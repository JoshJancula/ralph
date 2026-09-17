import { ResourceIdentity, ResourceIdentityCodec, ResourceIdentityBuilder, isTraversalAttempt } from './resource-identity';

describe('ResourceIdentity Integration Tests', () => {
  it('should encode identity from builder and decode it back', () => {
    const projects = [
      '/workspace/alice/project',
      '/workspace/bob/project',
      '/data/shared/project'
    ];

    const identities = projects.map((projectRoot) =>
      ResourceIdentityBuilder.forPlan(projectRoot, 'plans/PLAN1.md', 'PLAN1', 'source')
    );

    const encoded = identities.map((id) => ResourceIdentityCodec.encode(id));
    const decoded = encoded.map((enc) => ResourceIdentityCodec.decode(enc));

    decoded.forEach((id, idx) => {
      expect(id.projectRoot).toBe(identities[idx].projectRoot);
      expect(id.root).toBe(identities[idx].root);
      expect(id.kind).toBe(identities[idx].kind);
      expect(id.path).toBe(identities[idx].path);
      expect(id.displayName).toBe(identities[idx].displayName);
      expect(id.id).toBe(identities[idx].id);
      expect(id.source).toBe(identities[idx].source);
    });

    const uniqueIds = new Set(decoded.map((d) => d.id));
    expect(uniqueIds.size).toBe(projects.length);
  });

  it('should handle all resource kinds', () => {
    const projectRoot = '/home/user/project';
    const kinds = [
      { builder: ResourceIdentityBuilder.forPlan, root: 'plans', kind: 'plan' },
      { builder: ResourceIdentityBuilder.forLog, root: 'logs', kind: 'log' },
      { builder: ResourceIdentityBuilder.forArtifact, root: 'artifacts', kind: 'artifact' },
      { builder: ResourceIdentityBuilder.forWorkflow, root: 'workflows', kind: 'workflow' },
      { builder: ResourceIdentityBuilder.forRun, root: 'runs', kind: 'run' },
      { builder: ResourceIdentityBuilder.forDiscoverReport, root: 'artifacts', kind: 'discover-report' },
    ];

    for (const k of kinds) {
      const identity = k.builder(projectRoot, `test/${k.kind}.txt`, `Test ${k.kind}`);
      const encoded = ResourceIdentityCodec.encode(identity);
      const decoded = ResourceIdentityCodec.decode(encoded);

      expect(decoded.root).toBe(k.root);
      expect(decoded.kind).toBe(k.kind);
      expect(decoded.projectRoot).toBe(projectRoot);
    }
  });

  it('should distinguish source, control, and generated plans', () => {
    const projectRoot = '/home/user/project';
    const path = 'plans/PLAN42.md';
    const displayName = 'PLAN42';

    const source = ResourceIdentityBuilder.forPlan(projectRoot, path, displayName, 'source');
    const control = ResourceIdentityBuilder.forPlan(projectRoot, path, displayName, 'control');
    const generated = ResourceIdentityBuilder.forPlan(projectRoot, path, displayName, 'generated');

    const sourceEnc = ResourceIdentityCodec.encode(source);
    const controlEnc = ResourceIdentityCodec.encode(control);
    const generatedEnc = ResourceIdentityCodec.encode(generated);

    const sourceDec = ResourceIdentityCodec.decode(sourceEnc);
    const controlDec = ResourceIdentityCodec.decode(controlEnc);
    const generatedDec = ResourceIdentityCodec.decode(generatedEnc);

    expect(sourceDec.source).toBe('source');
    expect(controlDec.source).toBe('control');
    expect(generatedDec.source).toBe('generated');

    expect(sourceDec.path).toBe(path);
    expect(controlDec.path).toBe(path);
    expect(generatedDec.path).toBe(path);
  });

  it('should preserve complex paths through encoding/decoding', () => {
    const complexPaths = [
      'plans/2024-01/PLAN-001/control.md',
      'logs/PLAN-backup-v1.0/run-2024-01-15-14-32-45/output.log',
      'artifacts/benchmarks/report-2024-Q1.json',
      'workflows/deploy-to-prod-v2/definition.yaml',
    ];

    for (const path of complexPaths) {
      const identity = ResourceIdentityBuilder.forPlan(
        '/home/user/workspace',
        path,
        path.split('/').pop() || 'unknown',
        'source'
      );

      const encoded = ResourceIdentityCodec.encode(identity);
      const decoded = ResourceIdentityCodec.decode(encoded);

      expect(decoded.path).toBe(path);
      expect(decoded.projectRoot).toBe('/home/user/workspace');
    }
  });

  it('should reject invalid paths', () => {
    expect(isTraversalAttempt('../../../etc/passwd')).toBe(true);
    expect(isTraversalAttempt('/absolute/path')).toBe(true);
    expect(isTraversalAttempt('..\\windows\\path')).toBe(true);
    expect(isTraversalAttempt('normal/safe/path.txt')).toBe(false);
  });

  it('should ensure stable IDs for identical inputs', () => {
    const identity1a = ResourceIdentityBuilder.forPlan('/home/alice', 'PLAN1.md', 'PLAN1');
    const identity1b = ResourceIdentityBuilder.forPlan('/home/alice', 'PLAN1.md', 'PLAN1');

    const identity2 = ResourceIdentityBuilder.forPlan('/home/bob', 'PLAN1.md', 'PLAN1');

    expect(identity1a.id).toBe(identity1b.id);
    expect(identity1a.id).not.toBe(identity2.id);
  });

  it('should handle URL-safe encoding characters', () => {
    const identity = ResourceIdentityBuilder.forPlan(
      '/home/user/project-with-dashes_and_underscores',
      'plans/plan.v2.0+beta-1.md',
      'Plan v2.0+beta-1'
    );

    const encoded = ResourceIdentityCodec.encode(identity);
    expect(typeof encoded).toBe('string');
    expect(encoded.length).toBeGreaterThan(0);

    const decoded = ResourceIdentityCodec.decode(encoded);
    expect(decoded.projectRoot).toBe(identity.projectRoot);
    expect(decoded.displayName).toBe(identity.displayName);
  });

  it('should round-trip special characters in paths', () => {
    const specialPaths = [
      'plans/test (1).md',
      'logs/PLAN[backup]/output.log',
      'artifacts/report (2024-01-15).json',
    ];

    for (const path of specialPaths) {
      const identity = ResourceIdentityBuilder.forPlan('/home/user', path, 'Test');
      const encoded = ResourceIdentityCodec.encode(identity);
      const decoded = ResourceIdentityCodec.decode(encoded);
      expect(decoded.path).toBe(path);
    }
  });
});
