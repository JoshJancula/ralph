import '@angular/compiler';
import '@analogjs/vitest-angular/setup-zone';
import { TestBed } from '@angular/core/testing';
import { BrowserDynamicTestingModule, platformBrowserDynamicTesting } from '@angular/platform-browser-dynamic/testing';

declare const globalThis: { __ralphAngularTestEnv?: boolean };

if (!globalThis.__ralphAngularTestEnv) {
  TestBed.initTestEnvironment(BrowserDynamicTestingModule, platformBrowserDynamicTesting());
  globalThis.__ralphAngularTestEnv = true;
}
