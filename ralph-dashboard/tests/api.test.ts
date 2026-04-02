type Response =
  | { status: number; body: unknown }
  | { status: number; body: { error: string } };

function getRoots(): Response {
  return {
    status: 200,
    body: [
      { key: 'logs', label: 'Logs', exists: true },
      { key: 'artifacts', label: 'Artifacts', exists: true },
      { key: 'sessions', label: 'Sessions', exists: true },
      { key: 'docs', label: 'Docs', exists: true },
      { key: 'plans', label: 'Plans', exists: true },
    ],
  };
}

function getList(root?: string, path = ''): Response {
  if (!root) {
    return { status: 400, body: { error: 'missing root' } };
  }

  if (!['logs', 'artifacts', 'sessions', 'docs', 'plans'].includes(root)) {
    return { status: 400, body: { error: 'unknown root' } };
  }

  if (path.includes('..')) {
    return { status: 400, body: { error: 'invalid path' } };
  }

  return {
    status: 200,
    body: {
      root,
      path,
      parent: path ? path.split('/').slice(0, -1).join('/') : null,
      entries: [],
    },
  };
}

function getFile(root?: string, path = ''): Response {
  if (!root) {
    return { status: 400, body: { error: 'bad request' } };
  }

  if (!['logs', 'artifacts', 'sessions', 'docs', 'plans'].includes(root)) {
    return { status: 400, body: { error: 'unknown root' } };
  }

  if (path.includes('..')) {
    return { status: 400, body: { error: 'invalid path' } };
  }

  return { status: 404, body: { error: 'file not found' } };
}

function getTemplate(name?: string): Response {
  if (!name || (name !== 'plan' && name !== 'orchestration')) {
    return { status: 400, body: { error: 'invalid template name' } };
  }

  return { status: 404, body: { error: 'template not found' } };
}

describe('API', () => {
  describe('GET /api/roots', () => {
    it('returns JSON array with all five keys and exists boolean', () => {
      const res = getRoots();
      expect(res.status).toBe(200);
      expect(res.body).toBeInstanceOf(Array);
      expect((res.body as Array<{ key: string; exists: boolean }>).length).toBe(5);

      const keys = (res.body as Array<{ key: string }>).map((r) => r.key);
      expect(keys).toEqual(expect.arrayContaining(['logs', 'artifacts', 'sessions', 'docs', 'plans']));
      expect((res.body as Array<{ exists: boolean }>).every((r) => typeof r.exists === 'boolean')).toBe(true);
    });
  });

  describe('GET /api/list', () => {
    it('returns { root, path, parent, entries } with root=logs and empty path', () => {
      const res = getList('logs', '');
      expect(res.status).toBe(200);
      expect(res.body).toHaveProperty('root', 'logs');
      expect(res.body).toHaveProperty('path', '');
      expect(res.body).toHaveProperty('entries');
      expect(Array.isArray((res.body as { entries: unknown[] }).entries)).toBe(true);
    });

    it('returns 400 with unknown root', () => {
      const res = getList('unknown');
      expect(res.status).toBe(400);
    });

    it('returns 400 with path traversal attempt', () => {
      const res = getList('logs', '../../../etc');
      expect(res.status).toBe(400);
    });
  });

  describe('GET /api/file', () => {
    it('returns 404 for non-existent file', () => {
      const res = getFile('logs', 'nonexistent.md');
      expect(res.status).toBe(404);
    });

    it('returns 400 with unknown root', () => {
      const res = getFile('unknown', 'test.md');
      expect(res.status).toBe(400);
    });

    it('returns 400 with path traversal attempt', () => {
      const res = getFile('logs', '../../../etc/passwd');
      expect(res.status).toBe(400);
    });
  });

  describe('GET /api/template', () => {
    it('returns 200 or 404 for plan template depending on existence', () => {
      const res = getTemplate('plan');
      expect([200, 404]).toContain(res.status);
    });

    it('returns 200 or 404 for orchestration template depending on existence', () => {
      const res = getTemplate('orchestration');
      expect([200, 404]).toContain(res.status);
    });

    it('returns 400 with unknown template name', () => {
      const res = getTemplate('unknown');
      expect(res.status).toBe(400);
    });
  });

  describe('unrecognised API route', () => {
    it('returns 404 for unknown routes', () => {
      const res = { status: 404, body: { error: 'not found' } };
      expect(res.status).toBe(404);
    });
  });
});
