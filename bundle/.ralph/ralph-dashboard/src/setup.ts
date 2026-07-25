import '@angular/compiler';
import 'zone.js';
import 'zone.js/plugins/sync-test';
import 'zone.js/plugins/proxy';
import 'zone.js/testing';
import '@angular/platform-browser-dynamic';

import { getTestBed } from '@angular/core/testing';
import { BrowserTestingModule } from '@angular/platform-browser/testing';
import '@analogjs/vitest-angular/setup-snapshots';

const g = globalThis as typeof globalThis & { __ANGULAR_TESTBED_SETUP__?: boolean };

if (!g.__ANGULAR_TESTBED_SETUP__) {
  g.__ANGULAR_TESTBED_SETUP__ = true;
  try {
    getTestBed().initTestEnvironment([BrowserTestingModule], {
      teardown: { destroyAfterEach: true },
    });
  } catch (e) {
    console.error('INIT testbed error:', e);
  }
}
