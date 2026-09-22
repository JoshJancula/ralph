#!/usr/bin/env bash

ralph_dashboard_require_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then return 0; fi
  printf 'Error: Ralph dashboard requires Node.js 22.12.0 and npm.\nInstall it with nvm, then retry:\n  nvm install 22.12.0 && nvm use 22.12.0\nRalph will not install Node automatically.\n' >&2
  return 1
}
