/**
 * Regression tests for route-driven navigation in the dashboard.
 * Tests navigation via Angular routes (not hash-based).
 */
import { Component } from '@angular/core';
import { Routes } from '@angular/router';

import '../../angular-test-env';
import { TestBed } from '@angular/core/testing';
import { Router, NavigationEnd } from '@angular/router';
import { RouterTestingModule } from '@angular/router/testing';
import { firstValueFrom, filter } from 'rxjs';

import { NavService } from './nav.service';

/**
 * Dummy router outlet component that satisfies Angular's route validation.
 * NavService reads URL state client-side, so this component is never actually rendered.
 */
@Component({
  selector: 'app-dummy-outlet',
  standalone: true,
  template: '',
})
class DummyOutletComponent {}

/**
 * Test routes that accept any URL pattern without redirect.
 * Using redirect would change the URL and interfere with state restoration tests.
 */
const testRoutes: Routes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: '**', component: DummyOutletComponent },
];

describe('NavService - Route-Driven Navigation', () => {
  let router: Router;
  let service: NavService;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [RouterTestingModule.withRoutes(testRoutes)],
    });

    router = TestBed.inject(Router);
    service = TestBed.inject(NavService);
    await router.initialNavigation();
  });

  describe('Root selection via navigation', () => {
    it('navigate to root updates signals and URL', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('logs');
      await navEnd;

      expect(service.activeRoot()).toBe('logs');
      expect(router.url).toContain('/logs');
    });

    it('navigate to root with path updates root and path signals', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('plans', 'PLAN2');
      await navEnd;

      expect(service.activeRoot()).toBe('plans');
      expect(service.activePath()).toBe('PLAN2');
      expect(service.mode()).toBe('hub');
      expect(router.url).toContain('/plans');
      expect(router.parseUrl(router.url).queryParams['path']).toBe('PLAN2');
    });

    it('navigate to root with path and file updates all signals', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('logs', 'PLAN2', 'runner.log');
      await navEnd;

      expect(service.activeRoot()).toBe('logs');
      expect(service.activePath()).toBe('PLAN2');
      expect(service.activeFile()).toBe('runner.log');
      expect(service.mode()).toBe('file');
      expect(router.parseUrl(router.url).queryParams['path']).toBe('PLAN2');
      expect(router.parseUrl(router.url).queryParams['file']).toBe('runner.log');
    });
  });

  describe('Direct file links', () => {
    it('handles direct URL to file with file marker', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('logs', '', 'notes.md');
      await navEnd;

      expect(service.activeRoot()).toBe('logs');
      expect(service.activeFile()).toBe('notes.md');
      expect(service.mode()).toBe('file');
      expect(router.parseUrl(router.url).queryParams['file']).toBe('notes.md');
    });

    it('handles direct URL to nested file', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('plans', 'PLAN2', 'docs/notes.md');
      await navEnd;

      expect(service.activeRoot()).toBe('plans');
      expect(service.activePath()).toBe('PLAN2');
      expect(service.activeFile()).toBe('docs/notes.md');
      expect(service.mode()).toBe('file');
      expect(router.parseUrl(router.url).queryParams['file']).toBe('docs/notes.md');
    });

    it('handles URL with encoded special characters', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('docs', 'My Folder', 'file%20name.md');
      await navEnd;

      expect(service.activeRoot()).toBe('docs');
      expect(service.activePath()).toBe('My Folder');
      expect(service.activeFile()).toBe('file%20name.md');
    });
  });

  describe('Refresh/reload state restoration', () => {
    it('refresh re-parses the current URL after navigation completes', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('plans', 'PLAN2');
      await navEnd;
      service.refresh();

      expect(service.activeRoot()).toBe('plans');
      expect(service.activePath()).toBe('PLAN2');
    });

    it('refresh restores file state after navigation completes', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('logs', 'dir1', 'app.log');
      await navEnd;
      service.refresh();

      expect(service.activeRoot()).toBe('logs');
      expect(service.activePath()).toBe('dir1');
      expect(service.activeFile()).toBe('app.log');
      expect(service.mode()).toBe('file');
    });
  });

  describe('Mode switching', () => {
    it('navigate without file keeps hub mode', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('plans');
      await navEnd;

      expect(service.mode()).toBe('hub');
      expect(service.activeFile()).toBeNull();
    });

    it('navigate with file switches to file mode', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('plans', '', 'notes.md');
      await navEnd;

      expect(service.mode()).toBe('file');
      expect(service.activeFile()).toBe('notes.md');
    });
  });
});
