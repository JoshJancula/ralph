import { execFileSync } from 'node:child_process';
import { mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  delegationRootPath,
  delegationRunPath,
  graphRunPath,
  planAttemptPath,
  resolveStatePath,
  sequentialRunPath,
  sessionsDirPath,
  sessionsHomePath,
  stateLayoutVersion,
  stateSharedPath,
  workflowRunPath,
} from '../src/server/state-paths';
import { resolveGraphRunDir, resolvePlanRunDir } from '../src/server/dashboard-api';
import { resolveWorkflowRunDir } from '../src/server/workflow-api';
import { buildPlanRunEvidenceEntry } from '../src/server/plan-run-evidence';

let fixtureRoot = '';
let mixedRoot = '';
let v1Root = '';

describe('state paths', () => {
  beforeAll(() => {
    fixtureRoot = mkdtempSync(join(tmpdir(), 'ralph-state-paths-'));
    execFileSync('bash', [join(process.cwd(), '..', 'tests', 'fixtures', 'state-layout', 'generate-fixtures.sh'), fixtureRoot]);
    mixedRoot = join(fixtureRoot, 'mixed');
    v1Root = join(fixtureRoot, 'v1');
  });
  afterAll(() => rmSync(fixtureRoot, { recursive: true, force: true }));

  test('uses the catalog layout regardless of a later environment default', () => {
    expect(stateLayoutVersion(mixedRoot, 'run-2', '1')).toBe(2);
    expect(workflowRunPath(mixedRoot, 'run-2')).toBe(join(mixedRoot, 'runs/run-2/engine/workflow'));
    expect(graphRunPath(mixedRoot, 'demo', 'run-2')).toBe(join(mixedRoot, 'runs/run-2/engine/graph'));
  });

  test('uses v1 for an unknown run and shared paths respect the explicit layout', () => {
    expect(stateLayoutVersion(mixedRoot, 'missing', '2')).toBe(1);
    expect(stateSharedPath(mixedRoot, 'sessions', '2')).toBe(join(mixedRoot, 'internal/sessions'));
  });

  test('sessions home sticks to layout-1 when that plan already has sessions there', () => {
    const root = realpathSync(v1Root);
    expect(sessionsHomePath(root, 'demo', '2')).toBe(join(root, 'sessions'));
    expect(sessionsDirPath(root, 'demo', '2')).toBe(join(root, 'sessions', 'demo'));
    expect(sessionsHomePath(root, 'brand-new-plan', '2')).toBe(join(root, 'internal', 'sessions'));
  });

  test('refuses traversal and symlink escapes', () => {
    expect(() => resolveStatePath(mixedRoot, '../outside')).toThrow('Invalid state path');
    expect(() => resolveStatePath(mixedRoot, 'external-v1-link/nope')).toThrow('Invalid state path');
  });

  test('dashboard plan/graph/workflow readers resolve layout-1 and layout-2 fixtures', () => {
    const v1 = realpathSync(v1Root);
    const v2 = realpathSync(mixedRoot);

    expect(resolvePlanRunDir(v1, 'demo', 'plan-1')).toBe(join(v1, 'logs/demo/runs/plan-1'));
    expect(resolveGraphRunDir(v1, 'demo', 'graph-1')).toBe(join(v1, 'graph-runs/demo/graph-1'));
    expect(resolveWorkflowRunDir(v1, 'wf-1')).toBe(join(v1, 'workflow-runs/wf-1'));

    expect(resolvePlanRunDir(v2, 'demo', 'run-2')).toBe(join(v2, 'runs/run-2/stages/plan/attempts/run-2'));
    expect(resolveGraphRunDir(v2, 'demo', 'run-2')).toBe(join(v2, 'runs/run-2/engine/graph'));
    expect(resolveWorkflowRunDir(v2, 'run-2')).toBe(join(v2, 'runs/run-2/engine/workflow'));

    expect(planAttemptPath(v1, 'demo', 'plan-1')).toBe(resolvePlanRunDir(v1, 'demo', 'plan-1'));
    expect(graphRunPath(v2, 'demo', 'run-2')).toBe(resolveGraphRunDir(v2, 'demo', 'run-2'));
    expect(workflowRunPath(v2, 'run-2')).toBe(resolveWorkflowRunDir(v2, 'run-2'));
    expect(sequentialRunPath(v2, 'run-2', join(v2, 'workflow-runs/run-2/engine'))).toBe(
      join(v2, 'runs/run-2/engine/sequential'),
    );
    expect(delegationRootPath(v2, 'run-2')).toBe(join(v2, 'runs/run-2/engine/delegation'));
    expect(delegationRunPath(v2, 'run-2', 'delegated-run-0123456789abcdef01234567')).toBe(
      join(v2, 'runs/run-2/engine/delegation/delegated-run-0123456789abcdef01234567'),
    );
    expect(delegationRootPath(v1, 'graph-1')).toBe(join(v1, 'delegated-runs'));
  });

  test('plan-run evidence resolves layout-aware paths through state-paths', () => {
    const v1 = realpathSync(v1Root);
    const v2 = realpathSync(mixedRoot);
    const layout1 = buildPlanRunEvidenceEntry(v1, 'logs/demo/runs/run-1/output.log');
    expect(layout1?.path).toBe('logs/demo/runs/run-1/output.log');
    expect(layout1?.target.root).toBe('logs');

    const layout2 = buildPlanRunEvidenceEntry(v2, 'runs/run-2/stages/plan/attempts/run-2/output.log');
    expect(layout2?.path).toBe('runs/run-2/stages/plan/attempts/run-2/output.log');
    expect(layout2?.target.root).toBe('runs');
  });
});
