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
 * Test routes that accept any URL pattern.
 * NavService parses the URL client-side to extract root/path/file state.
 */
const testRoutes: Routes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: '**', component: DummyOutletComponent },
];

describe('NavService', () => {
  let router: Router;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [RouterTestingModule.withRoutes(testRoutes)],
    });

    router = TestBed.inject(Router);
    await router.initialNavigation();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('initial state reflects the current route after initial navigation', () => {
    const service = TestBed.inject(NavService);
    expect(service.activeRoot()).toBe('plans');
    expect(service.activePath()).toBeNull();
    expect(service.activeFile()).toBeNull();
    expect(service.mode()).toBe('hub');
  });

  it('navigate updates signals and URL', async () => {
    const service = TestBed.inject(NavService);
    const navEnd = firstValueFrom(
      router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
    );

    service.navigate('logs', 'PLAN2', 'plan-runner.log');
    await navEnd;

    expect(service.activeRoot()).toBe('logs');
    expect(service.activePath()).toBe('PLAN2');
    expect(service.activeFile()).toBe('plan-runner.log');
    expect(router.url).toContain('/logs');
    expect(router.url).toContain('path=PLAN2');
    expect(router.url).toContain('file=plan-runner.log');
  });

  it('navigate rejection does not update signals', async () => {
    const service = TestBed.inject(NavService);
    await router.navigateByUrl('/logs?path=PLAN2&file=plan-runner.log');

    expect(service.activeRoot()).toBe('logs');
    expect(service.activePath()).toBe('PLAN2');
    expect(service.activeFile()).toBe('plan-runner.log');
    expect(service.mode()).toBe('file');

    const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const navigateSpy = vi.spyOn(router, 'navigateByUrl').mockRejectedValueOnce(new Error('Navigation blocked'));

    service.navigate('plans', 'PLAN3', 'notes.md');
    await Promise.resolve();
    await Promise.resolve();

    expect(navigateSpy).toHaveBeenCalledWith(expect.stringContaining('/plans'));
    expect(service.activeRoot()).toBe('logs');
    expect(service.activePath()).toBe('PLAN2');
    expect(service.activeFile()).toBe('plan-runner.log');
    expect(service.mode()).toBe('file');

    expect(consoleSpy).toHaveBeenCalled();
    const loggedMessage = consoleSpy.mock.calls[0]?.[0] ?? '';
    expect(loggedMessage).toContain('Navigation to /plans');
    expect(loggedMessage).toContain('Navigation blocked');
  });

  it('direct navigation updates state from URL', async () => {
    const service = TestBed.inject(NavService);
    await router.navigateByUrl('/alpha?path=beta&file=gamma.txt');

    expect(service.activeRoot()).toBe('alpha');
    expect(service.activePath()).toBe('beta');
    expect(service.activeFile()).toBe('gamma.txt');
    expect(service.mode()).toBe('file');
  });

  it('navigate without file keeps hub mode and with file flips mode', async () => {
    const service = TestBed.inject(NavService);
    const hubNav = firstValueFrom(
      router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
    );

    service.navigate('plans');
    await hubNav;
    expect(service.mode()).toBe('hub');
    expect(service.activeFile()).toBeNull();

    const fileNav = firstValueFrom(
      router.events.pipe(filter((event): event is NavigationEnd => event instanceof NavigationEnd)),
    );

     service.navigate('logs', '', 'runner.log');
     await fileNav;
     expect(service.mode()).toBe('file');
     expect(service.activeFile()).toBe('runner.log');
   });

   it('refresh re-parses the current URL', () => {
     const service = TestBed.inject(NavService);
     const spy = vi.spyOn(service as any, 'updateStateFromRoute' as any);
     service.refresh();
     expect(spy).toHaveBeenCalled();
   });

  it('navigate ignores empty root string', () => {
    const service = TestBed.inject(NavService);
    const originalNav = service['router'].navigate;
    const spy = vi.spyOn(service['router'], 'navigate');

    service.navigate('');
    service.navigate('   ');

    expect(spy).not.toHaveBeenCalled();
  });

  it('decodeSegment returns original segment when decodeURIComponent fails', () => {
    const service = TestBed.inject(NavService);
    const decodeSegment = (service as any).decodeSegment;
    
    // Mock decodeURIComponent to throw
    const originalDecode = globalThis.decodeURIComponent;
    (globalThis as any).decodeURIComponent = () => {
      throw new Error('Decode failed');
    };

    const result = decodeSegment('%20test%20');
    expect(result).toBe('%20test%20');

    // Restore
    (globalThis as any).decodeURIComponent = originalDecode;
  });
});
