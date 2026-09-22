import { Component } from '@angular/core';
import { Routes } from '@angular/router';

import '../../angular-test-env';
import { TestBed } from '@angular/core/testing';
import { Router, NavigationEnd } from '@angular/router';
import { RouterTestingModule } from '@angular/router/testing';
import { firstValueFrom, filter } from 'rxjs';

import { NavService } from './nav.service';

@Component({
  selector: 'app-dummy-outlet',
  standalone: true,
  template: '',
})
class DummyOutletComponent {}

const testRoutes: Routes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: '**', component: DummyOutletComponent },
];

describe('NavService - Legacy Route Compatibility', () => {
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

  describe('Legacy query-based navigation', () => {
    it('handles /plans?file=notes.md', async () => {
      await router.navigateByUrl('/plans?file=notes.md');

      expect(service.activeRoot()).toBe('plans');
      expect(service.activeFile()).toBe('notes.md');
      expect(service.activeSection()).toBe('plans');
    });

    it('handles /plans?path=PLAN2&file=notes.md', async () => {
      await router.navigateByUrl('/plans?path=PLAN2&file=notes.md');

      expect(service.activeRoot()).toBe('plans');
      expect(service.activePath()).toBe('PLAN2');
      expect(service.activeFile()).toBe('notes.md');
      expect(service.activeSection()).toBe('plans');
    });

    it('handles /docs with projectRoot query param', async () => {
      await router.navigateByUrl('/docs?projectRoot=/my/project');

      expect(service.activeRoot()).toBe('docs');
      expect(service.activeProjectRoot()).toBe('/my/project');
      expect(service.activeSection()).toBe('docs');
    });

    it('handles /logs with workspaceRoot query param', async () => {
      await router.navigateByUrl('/logs?workspaceRoot=/my/workspace');

      expect(service.activeRoot()).toBe('logs');
      expect(service.activeWorkspaceRoot()).toBe('/my/workspace');
      expect(service.activeSection()).toBe('browse');
    });

    it('preserves root-based browse URLs like /docs', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('docs');
      await navEnd;

      expect(service.activeRoot()).toBe('docs');
      expect(service.activeSection()).toBe('docs');
      expect(router.url).toContain('/docs');
    });

    it('preserves root-based browse URLs like /logs', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('logs');
      await navEnd;

      expect(service.activeRoot()).toBe('logs');
      expect(service.activeSection()).toBe('browse');
      expect(router.url).toContain('/logs');
    });

    it('handles encoded special characters in legacy URLs', async () => {
      await router.navigateByUrl('/plans?path=My%20Folder&file=file%20name.md');

      expect(service.activeRoot()).toBe('plans');
      expect(service.activePath()).toBe('My Folder');
      expect(service.activeFile()).toBe('file name.md');
    });
  });
});
