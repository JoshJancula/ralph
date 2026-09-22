import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

import type { AmbientCollectorPaths } from './types';

export function resolveAmbientCollectorPaths(home = homedir()): AmbientCollectorPaths {
  const claudeDirCandidates = [
    join(home, '.claude'),
    join(home, '.config', 'claude'),
  ];
  let claudeDir = claudeDirCandidates[0];
  for (const candidate of claudeDirCandidates) {
    if (existsSync(candidate)) {
      claudeDir = candidate;
      break;
    }
  }

  return {
    homeDir: home,
    claudeDir,
    claudeJsonPath: join(home, '.claude.json'),
    codexSessionsDir: join(home, '.codex', 'sessions'),
  };
}
