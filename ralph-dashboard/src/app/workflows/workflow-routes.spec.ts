import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { Router } from '@angular/router';
import { RouterTestingModule } from '@angular/router/testing';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { routes } from '../app.routes';

/**
 * Regression test for the workflows routes added ahead of the pre-existing
 * `:root` catch-all family in app.routes.ts. Before those entries existed,
 * `/workflows` would have matched `:root` (root === 'workflows') and
 * rendered WorkspaceViewComponent's file-browsing "browse"/"empty" state
 * instead of the workflows studio.
 */
describe('workflow routes precede the :root catch-all', () => {
  let router: Router;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [RouterTestingModule.withRoutes(routes), HttpClientTestingModule],
    });
    router = TestBed.inject(Router);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('routes.ts declares the workflows paths before the :root family', () => {
    const paths = routes.map((route) => route.path);
    const workflowsIndex = paths.indexOf('workflows');
    const rootCatchAllIndex = paths.indexOf(':root');
    expect(workflowsIndex).toBeGreaterThanOrEqual(0);
    expect(rootCatchAllIndex).toBeGreaterThanOrEqual(0);
    expect(workflowsIndex).toBeLessThan(rootCatchAllIndex);

    for (const path of ['workflows/new', 'workflows/:id', 'workflows/:id/edit']) {
      const index = paths.indexOf(path);
      expect(index).toBeGreaterThanOrEqual(0);
      expect(index).toBeLessThan(rootCatchAllIndex);
    }
  });

  it('navigating to /workflows resolves the workflows list route, not :root', async () => {
    // No <router-outlet> is mounted in this test, so lazy page components
    // (and the HTTP calls their ngOnInit would make) never activate — only
    // route-config resolution is under test here.
    await router.navigateByUrl('/workflows');
    httpMock.verify();

    const matched = router.routerState.snapshot.root.firstChild;
    expect(matched?.routeConfig?.path).toBe('workflows');
    expect(matched?.routeConfig?.path).not.toBe(':root');
  });

  it('navigating to /workflows/bug-fix resolves the workflow detail route, not :root', async () => {
    await router.navigateByUrl('/workflows/bug-fix');
    httpMock.verify();

    const matched = router.routerState.snapshot.root.firstChild;
    expect(matched?.routeConfig?.path).toBe('workflows/:id');
  });

  it('navigating to /workflows/new and /workflows/bug-fix/edit resolve their own routes, not :root', async () => {
    await router.navigateByUrl('/workflows/new');
    expect(router.routerState.snapshot.root.firstChild?.routeConfig?.path).toBe('workflows/new');

    await router.navigateByUrl('/workflows/bug-fix/edit');
    expect(router.routerState.snapshot.root.firstChild?.routeConfig?.path).toBe('workflows/:id/edit');
  });
});
