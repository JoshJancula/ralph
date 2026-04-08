export function parseDashboardFileHash(hash: string): { root: string; path: string; file: string } | null {
  if (!hash || !hash.startsWith('#')) {
    return null;
  }

  const queryString = hash.slice(1);
  const params = new URLSearchParams(queryString);

  const root = params.get('root');
  const path = params.get('path');
  const file = params.get('file');

  if (!root || path === null || file === null) {
    return null;
  }

  return { root, path, file };
}

export function buildDashboardFileHash(root: string, path: string, file: string): string {
  const params = new URLSearchParams({
    root,
    path,
    file,
  });

  return `#${params.toString()}`;
}
