const Module = require('node:module');
const path = require('node:path');

const originalLoad = Module._load;
const launchServerPath = path.normalize(
  path.join(
    __dirname,
    '..',
    'node_modules',
    '@angular',
    'build',
    'src',
    'utils',
    'server-rendering',
    'launch-server.js',
  ),
);
const manifestState = globalThis.__RALPH_ANGULAR_MANIFEST_STATE__ || {
  patched: false,
};
globalThis.__RALPH_ANGULAR_MANIFEST_STATE__ = manifestState;

function createEngineManifest() {
  return {
    basePath: '/',
    allowedHosts: ['localhost', '127.0.0.1'],
    supportedLocales: {
      en: '',
    },
    entryPoints: {
      '': () => import('./main.server.mjs'),
    },
  };
}

function createAppManifest() {
  return {
    baseHref: '/',
    assets: {},
    bootstrap: () => import('./main.server.mjs').then((m) => m.default),
    routes: undefined,
    locale: undefined,
    entryPointToBrowserMapping: undefined,
  };
}

function seedAngularManifests(exportsObj) {
  if (manifestState.patched || !exportsObj) {
    return;
  }

  const setEngineManifest = exportsObj.ɵsetAngularAppEngineManifest;
  const setAppManifest = exportsObj.ɵsetAngularAppManifest;
  if (typeof setEngineManifest === 'function') {
    setEngineManifest(createEngineManifest());
  }
  if (typeof setAppManifest === 'function') {
    setAppManifest(createAppManifest());
  }
  manifestState.patched = true;
}

Module._load = function patchedLoad(request, parent, isMain) {
  try {
    const resolved = Module._resolveFilename(request, parent, isMain);
    if (path.normalize(resolved) === launchServerPath) {
      const DEFAULT_URL = new URL('http://ng-localhost/');
      return {
        DEFAULT_URL,
        launchServer: async () => DEFAULT_URL,
      };
    }
    if (
      resolved === '@angular/ssr' ||
      path.normalize(resolved).endsWith(`${path.sep}@angular${path.sep}ssr${path.sep}fesm2022${path.sep}ssr.mjs`)
    ) {
      const exportsObj = originalLoad.apply(this, arguments);
      seedAngularManifests(exportsObj);
      return exportsObj;
    }
  } catch {
    // Fall through to the original loader for non-resolvable requests.
  }

  return originalLoad.apply(this, arguments);
};
