import { ResourceIdentityCodec, ResourceIdentityBuilder, isTraversalAttempt } from './resource-identity';

describe('ResourceIdentityCodec', () => {
  it('should encode and decode a resource identity', () => {
    const identity = ResourceIdentityBuilder.forPlan(
      '/home/user/project1',
      'plans/test-plan.md',
      'Test Plan',
      'source'
    );

    const encoded = ResourceIdentityCodec.encode(identity);
    expect(typeof encoded).toBe('string');
    expect(encoded.length).toBeGreaterThan(0);

    const decoded = ResourceIdentityCodec.decode(encoded);
    expect(decoded.projectRoot).toBe('/home/user/project1');
    expect(decoded.root).toBe('plans');
    expect(decoded.kind).toBe('plan');
    expect(decoded.path).toBe('plans/test-plan.md');
    expect(decoded.displayName).toBe('Test Plan');
    expect(decoded.source).toBe('source');
  });

  it('should handle identities without optional source field', () => {
    const identity = ResourceIdentityBuilder.forLog(
      '/home/user/project1',
      'logs/run-123/output.log',
      'Run 123 Log'
    );

    const encoded = ResourceIdentityCodec.encode(identity);
    const decoded = ResourceIdentityCodec.decode(encoded);

    expect(decoded.projectRoot).toBe('/home/user/project1');
    expect(decoded.root).toBe('logs');
    expect(decoded.kind).toBe('log');
    expect(decoded.source).toBeUndefined();
  });

  it('should throw on invalid base64', () => {
    expect(() => ResourceIdentityCodec.decode('not-valid-base64!!!')).toThrow('Failed to decode resource identity');
  });

  it('should throw on malformed JSON', () => {
    const invalidEncoded = Buffer.from('{"invalid": "json"', 'utf8').toString('base64url');
    expect(() => ResourceIdentityCodec.decode(invalidEncoded)).toThrow('Failed to decode resource identity');
  });

  it('should throw on missing required fields', () => {
    const incomplete = { projectRoot: '/home/user/project1', root: 'plans' };
    const json = JSON.stringify(incomplete);
    const encoded = Buffer.from(json).toString('base64url');
    expect(() => ResourceIdentityCodec.decode(encoded)).toThrow('Failed to decode resource identity');
  });
});

describe('ResourceIdentityBuilder', () => {
  it('should create distinct IDs for same filename in different projects', () => {
    const plan1 = ResourceIdentityBuilder.forPlan(
      '/home/user/project1',
      'PLAN17.md',
      'PLAN17',
      'source'
    );
    const plan2 = ResourceIdentityBuilder.forPlan(
      '/home/user/project2',
      'PLAN17.md',
      'PLAN17',
      'source'
    );

    expect(plan1.id).not.toBe(plan2.id);
    expect(plan1.projectRoot).not.toBe(plan2.projectRoot);
  });

  it('should encode stable ID consistently', () => {
    const plan1 = ResourceIdentityBuilder.forPlan(
      '/home/user/project1',
      'plans/test.md',
      'Test'
    );
    const plan2 = ResourceIdentityBuilder.forPlan(
      '/home/user/project1',
      'plans/test.md',
      'Test'
    );

    expect(plan1.id).toBe(plan2.id);
  });

  it('should create different IDs for different paths even with same name', () => {
    const plan1 = ResourceIdentityBuilder.forPlan(
      '/home/user/project1',
      'plans/test.md',
      'Test'
    );
    const plan2 = ResourceIdentityBuilder.forPlan(
      '/home/user/project1',
      'archive/test.md',
      'Test'
    );

    expect(plan1.id).not.toBe(plan2.id);
  });

  it('should preserve all fields in plan identity', () => {
    const plan = ResourceIdentityBuilder.forPlan(
      '/home/user/project1',
      'plans/PLAN17.md',
      'Plan 17',
      'control'
    );

    expect(plan.projectRoot).toBe('/home/user/project1');
    expect(plan.root).toBe('plans');
    expect(plan.kind).toBe('plan');
    expect(plan.path).toBe('plans/PLAN17.md');
    expect(plan.displayName).toBe('Plan 17');
    expect(plan.source).toBe('control');
  });

  it('should create log identity with correct root', () => {
    const log = ResourceIdentityBuilder.forLog(
      '/home/user/project1',
      'logs/PLAN17/run-001/output.log',
      'Run 001 Log'
    );

    expect(log.root).toBe('logs');
    expect(log.kind).toBe('log');
  });

  it('should create artifact identity with correct root', () => {
    const artifact = ResourceIdentityBuilder.forArtifact(
      '/home/user/project1',
      'artifacts/benchmark.json',
      'Benchmark Report'
    );

    expect(artifact.root).toBe('artifacts');
    expect(artifact.kind).toBe('artifact');
  });

  it('should create workflow identity', () => {
    const workflow = ResourceIdentityBuilder.forWorkflow(
      '/home/user/project1',
      'workflows/deploy.yaml',
      'Deploy Workflow'
    );

    expect(workflow.root).toBe('workflows');
    expect(workflow.kind).toBe('workflow');
  });

  it('should create run identity', () => {
    const run = ResourceIdentityBuilder.forRun(
      '/home/user/project1',
      'runs/run-123',
      'Run 123'
    );

    expect(run.root).toBe('runs');
    expect(run.kind).toBe('run');
  });

  it('should create discover-report identity', () => {
    const report = ResourceIdentityBuilder.forDiscoverReport(
      '/home/user/project1',
      'artifacts/PLAN17/discover-report.json',
      'Discover Report'
    );

    expect(report.root).toBe('artifacts');
    expect(report.kind).toBe('discover-report');
  });
});

describe('isTraversalAttempt', () => {
  it('should detect parent directory references with ..', () => {
    expect(isTraversalAttempt('../../../etc/passwd')).toBe(true);
    expect(isTraversalAttempt('plans/../logs/file.log')).toBe(true);
  });

  it('should detect absolute paths', () => {
    expect(isTraversalAttempt('/etc/passwd')).toBe(true);
    expect(isTraversalAttempt('/home/user/project/plan.md')).toBe(true);
  });

  it('should allow safe relative paths', () => {
    expect(isTraversalAttempt('plans/PLAN17.md')).toBe(false);
    expect(isTraversalAttempt('logs/run-123/output.log')).toBe(false);
    expect(isTraversalAttempt('artifacts/benchmark.json')).toBe(false);
  });

  it('should handle Windows-style paths', () => {
    expect(isTraversalAttempt('..\\..\\etc\\passwd')).toBe(true);
  });

  it('should allow empty string', () => {
    expect(isTraversalAttempt('')).toBe(false);
  });

  it('should handle deeply nested safe paths', () => {
    expect(isTraversalAttempt('logs/PLAN17/run-001/2024-01-15/output.log')).toBe(false);
  });
});

describe('serialization round-trip', () => {
  it('should preserve all fields for plan with source provenance', () => {
    const original = ResourceIdentityBuilder.forPlan(
      '/home/alice/workspace',
      'plans/feature-delivery.md',
      'Feature Delivery',
      'source'
    );

    const encoded = ResourceIdentityCodec.encode(original);
    const decoded = ResourceIdentityCodec.decode(encoded);

    expect(decoded.projectRoot).toBe(original.projectRoot);
    expect(decoded.root).toBe(original.root);
    expect(decoded.kind).toBe(original.kind);
    expect(decoded.path).toBe(original.path);
    expect(decoded.displayName).toBe(original.displayName);
    expect(decoded.source).toBe(original.source);
    expect(decoded.id).toBe(original.id);
  });

  it('should preserve all fields for log identity', () => {
    const original = ResourceIdentityBuilder.forLog(
      '/home/bob/workspace',
      'logs/PLAN42/run-latest/output.log',
      'Latest Run'
    );

    const encoded = ResourceIdentityCodec.encode(original);
    const decoded = ResourceIdentityCodec.decode(encoded);

    expect(decoded.projectRoot).toBe(original.projectRoot);
    expect(decoded.root).toBe(original.root);
    expect(decoded.kind).toBe(original.kind);
    expect(decoded.path).toBe(original.path);
    expect(decoded.displayName).toBe(original.displayName);
    expect(decoded.id).toBe(original.id);
  });

  it('should handle special characters in paths and display names', () => {
    const original = ResourceIdentityBuilder.forPlan(
      '/home/user/project-2024',
      'plans/my-plan-v2.3.md',
      'My Plan (v2.3) - Updated',
      'control'
    );

    const encoded = ResourceIdentityCodec.encode(original);
    const decoded = ResourceIdentityCodec.decode(encoded);

    expect(decoded.path).toBe(original.path);
    expect(decoded.displayName).toBe(original.displayName);
  });
});

describe('duplicate filename disambiguation', () => {
  it('should create distinct identities for same filename in different projects', () => {
    const projects = [
      '/workspace/alice/project',
      '/workspace/bob/project',
      '/data/shared/project'
    ];

    const identities = projects.map((proj) =>
      ResourceIdentityBuilder.forPlan(proj, 'PLAN1.md', 'PLAN1', 'source')
    );

    const ids = identities.map((i) => i.id);
    const uniqueIds = new Set(ids);

    expect(uniqueIds.size).toBe(projects.length);
    expect(identities.every((i, idx) => i.projectRoot === projects[idx])).toBe(true);
  });

  it('should distinguish control vs source copies of same plan', () => {
    const projectRoot = '/home/user/project';
    const path = 'plans/PLAN1.md';

    const source = ResourceIdentityBuilder.forPlan(projectRoot, path, 'PLAN1', 'source');
    const control = ResourceIdentityBuilder.forPlan(projectRoot, path, 'PLAN1', 'control');

    expect(source.source).toBe('source');
    expect(control.source).toBe('control');
    expect(source.path).toBe(control.path);
    expect(source.projectRoot).toBe(control.projectRoot);
  });
});
