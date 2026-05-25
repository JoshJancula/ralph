import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { resolveRalphDocumentationDir, resolveRalphInstallRoot } from '../src/paths';

describe('resolveRalphDocumentationDir', () => {
  let tempRoot = '';
  let originalDocsRoot: string | undefined;
  let originalRalphHome: string | undefined;

  beforeEach(() => {
    originalDocsRoot = process.env['RALPH_DOCS_ROOT'];
    originalRalphHome = process.env['RALPH_HOME'];
    delete process.env['RALPH_DOCS_ROOT'];
    delete process.env['RALPH_HOME'];
    tempRoot = realpathSync(mkdtempSync(join(tmpdir(), 'ralph-docs-resolve-')));
  });

  afterEach(() => {
    if (originalDocsRoot === undefined) {
      delete process.env['RALPH_DOCS_ROOT'];
    } else {
      process.env['RALPH_DOCS_ROOT'] = originalDocsRoot;
    }
    if (originalRalphHome === undefined) {
      delete process.env['RALPH_HOME'];
    } else {
      process.env['RALPH_HOME'] = originalRalphHome;
    }
    if (tempRoot) {
      rmSync(tempRoot, { recursive: true, force: true });
    }
  });

  it('uses RALPH_DOCS_ROOT when set', () => {
    const custom = join(tempRoot, 'custom-docs');
    mkdirSync(custom, { recursive: true });
    process.env['RALPH_DOCS_ROOT'] = custom;
    expect(resolveRalphDocumentationDir(join(tempRoot, 'proj'))).toBe(custom);
  });

  it('prefers project docs when the directory has visible entries', () => {
    const proj = join(tempRoot, 'proj');
    const docs = join(proj, 'docs');
    mkdirSync(docs, { recursive: true });
    writeFileSync(join(docs, 'readme.md'), '# local');
    expect(resolveRalphDocumentationDir(proj)).toBe(docs);
  });

  it('does not fall back to RALPH_HOME docs for other projects', () => {
    const install = join(tempRoot, 'ralph-home');
    const frameworkDocs = join(install, 'docs');
    mkdirSync(frameworkDocs, { recursive: true });
    writeFileSync(join(frameworkDocs, 'README.md'), '# Ralph docs\n');
    writeFileSync(join(frameworkDocs, 'INSTALL.md'), '# install\n');
    process.env['RALPH_HOME'] = install;

    const proj = join(tempRoot, 'coinbase-node');
    mkdirSync(proj, { recursive: true });
    const resolved = resolveRalphDocumentationDir(proj);
    expect(resolved).not.toBe(frameworkDocs);
    expect(resolved).toContain('__ralph-hidden-docs__');
  });

  it('hides Ralph framework docs copied into a project docs directory', () => {
    const proj = join(tempRoot, 'installed-project');
    const docs = join(proj, 'docs');
    mkdirSync(docs, { recursive: true });
    writeFileSync(join(docs, 'README.md'), '# Ralph docs\n');
    writeFileSync(join(docs, 'GLOBAL-INSTALL.md'), '# global\n');
    const resolved = resolveRalphDocumentationDir(proj);
    expect(resolved).not.toBe(docs);
    expect(resolved).toContain('__ralph-hidden-docs__');
  });

  it('uses RALPH_HOME docs for the install root project', () => {
    const install = join(tempRoot, 'ralph-home');
    const frameworkDocs = join(install, 'docs');
    mkdirSync(join(install, 'bundle', '.ralph'), { recursive: true });
    mkdirSync(frameworkDocs, { recursive: true });
    writeFileSync(join(frameworkDocs, 'README.md'), '# Ralph docs\n');
    process.env['RALPH_HOME'] = install;
    expect(resolveRalphDocumentationDir(install)).toBe(frameworkDocs);
  });
});

describe('resolveRalphInstallRoot', () => {
  let tempRoot = '';
  let originalRalphHome: string | undefined;

  beforeEach(() => {
    originalRalphHome = process.env['RALPH_HOME'];
    delete process.env['RALPH_HOME'];
    tempRoot = realpathSync(mkdtempSync(join(tmpdir(), 'ralph-install-root-')));
  });

  afterEach(() => {
    if (originalRalphHome === undefined) {
      delete process.env['RALPH_HOME'];
    } else {
      process.env['RALPH_HOME'] = originalRalphHome;
    }
    if (tempRoot) {
      rmSync(tempRoot, { recursive: true, force: true });
    }
  });

  it('returns RALPH_HOME when the directory exists', () => {
    process.env['RALPH_HOME'] = tempRoot;
    expect(resolveRalphInstallRoot()).toBe(tempRoot);
  });
});
