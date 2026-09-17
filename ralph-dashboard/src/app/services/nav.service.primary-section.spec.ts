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

describe('NavService - Primary Section Navigation', () => {
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

  describe('Active section detection', () => {
    it('defaults to home section', () => {
      expect(service.activeSection()).toBe('home');
    });

    it('detects home section from /home route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('home');
      await navEnd;

      expect(service.activeSection()).toBe('home');
    });

    it('detects runs section from /runs route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('runs');
      await navEnd;

      expect(service.activeSection()).toBe('runs');
    });

    it('detects plans section from /plans route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('plans');
      await navEnd;

      expect(service.activeSection()).toBe('plans');
    });

    it('detects workflows section from /workflows route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('workflows');
      await navEnd;

      expect(service.activeSection()).toBe('workflows');
    });

    it('detects insights section from /insights route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('insights');
      await navEnd;

      expect(service.activeSection()).toBe('insights');
    });

    it('detects insights section from /usage route (legacy)', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('usage');
      await navEnd;

      expect(service.activeSection()).toBe('insights');
    });

    it('detects docs section from /docs route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('docs');
      await navEnd;

      expect(service.activeSection()).toBe('docs');
    });

    it('detects browse section from /logs route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('logs');
      await navEnd;

      expect(service.activeSection()).toBe('browse');
    });

    it('detects browse section from /artifacts route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('artifacts');
      await navEnd;

      expect(service.activeSection()).toBe('browse');
    });

    it('detects browse section from /sessions route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('sessions');
      await navEnd;

      expect(service.activeSection()).toBe('browse');
    });

    it('detects browse section from /orchestration-plans route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('orchestration-plans');
      await navEnd;

      expect(service.activeSection()).toBe('browse');
    });

    it('detects browse section from /graph-runs route', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('graph-runs');
      await navEnd;

      expect(service.activeSection()).toBe('browse');
    });
  });

  describe('Section persistence across file navigation', () => {
    it('maintains docs section when navigating within docs with file', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('docs', '', 'README.md');
      await navEnd;

      expect(service.activeSection()).toBe('docs');
      expect(service.activeRoot()).toBe('docs');
      expect(service.activeFile()).toBe('README.md');
      expect(router.url).toContain('/docs/file/README.md');
    });

    it('maintains plans section when navigating to a plan file', async () => {
      const navEnd = firstValueFrom(
        router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
      );

      service.navigate('plans', 'PLAN1', 'notes.md');
      await navEnd;

      expect(service.activeSection()).toBe('plans');
      expect(service.activeRoot()).toBe('plans');
      expect(service.activeFile()).toBe('notes.md');
    });
  });

  describe('Direct URL navigation', () => {
    it('parses /home route correctly', async () => {
      await router.navigateByUrl('/home');

      expect(service.activeSection()).toBe('home');
      expect(service.activeRoot()).toBe('home');
    });

    it('parses /runs route correctly', async () => {
      await router.navigateByUrl('/runs');

      expect(service.activeSection()).toBe('runs');
      expect(service.activeRoot()).toBe('runs');
    });

    it('parses /insights route correctly', async () => {
      await router.navigateByUrl('/insights');

      expect(service.activeSection()).toBe('insights');
      expect(service.activeRoot()).toBe('insights');
    });
  });
});
